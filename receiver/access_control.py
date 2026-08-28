from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from .database import Database
from .identity import register_device, validate_device_registration


PAIRING_LIFETIME = timedelta(minutes=10)
LOCAL_PAIRING_LIFETIME = timedelta(minutes=10)
PAIRING_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"


class AccessControlError(ValueError):
    pass


def _now() -> datetime:
    return datetime.now(UTC)


def _timestamp(value: datetime) -> str:
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _secret_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _normalize_pairing_code(value: str) -> str:
    return "".join(character for character in value.upper() if character.isalnum())


class AccessControl:
    """Owns short-lived, single-use device pairing credentials.

    Dashboard access is authenticated by the local OS or Tailscale Serve and is
    deliberately not represented by another password in this database.
    """

    def __init__(self, database: Database) -> None:
        self.database = database

    def create_pairing_session(
        self,
        owner_id: str = "owner-default",
        lifetime: timedelta = PAIRING_LIFETIME,
    ) -> dict[str, Any]:
        code_raw = "".join(secrets.choice(PAIRING_ALPHABET) for _ in range(12))
        display_code = "-".join(code_raw[index:index + 4] for index in range(0, 12, 4))
        now = _now()
        session_id = str(uuid.uuid4())
        with self.database.connection() as connection:
            connection.execute(
                """UPDATE pairing_sessions SET revoked_at = ?
                   WHERE consumed_at IS NULL AND revoked_at IS NULL AND expires_at > ?""",
                (_timestamp(now), _timestamp(now)),
            )
            connection.execute(
                """INSERT INTO pairing_sessions(
                       session_id, owner_id, code_hash, created_at, expires_at
                   ) VALUES (?, ?, ?, ?, ?)""",
                (
                    session_id,
                    owner_id,
                    _secret_hash(code_raw),
                    _timestamp(now),
                    _timestamp(now + lifetime),
                ),
            )
        return {
            "session_id": session_id,
            "pairing_code": display_code,
            "created_at": _timestamp(now),
            "expires_at": _timestamp(now + lifetime),
            "single_use": True,
        }

    def register_device_with_pairing_code(
        self,
        pairing_code: str,
        payload: dict[str, Any],
    ) -> dict[str, Any]:
        normalized_code = _normalize_pairing_code(pairing_code)
        if len(normalized_code) != 12 or any(ch not in PAIRING_ALPHABET for ch in normalized_code):
            raise AccessControlError("配对码无效、已过期或已经使用")

        required = {"device_id", "display_name", "signing_key_id", "signing_public_key_base64"}
        missing = required - payload.keys()
        if missing:
            raise AccessControlError(f"缺少字段：{', '.join(sorted(missing))}")

        now = _now()
        code_hash = _secret_hash(normalized_code)
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM pairing_sessions WHERE code_hash = ?",
                (code_hash,),
            ).fetchone()
            if (
                row is None
                or row["consumed_at"] is not None
                or row["revoked_at"] is not None
                or _parse_timestamp(row["expires_at"]) <= now
            ):
                raise AccessControlError("配对码无效、已过期或已经使用")

            device = register_device(
                self.database,
                str(row["owner_id"]),
                str(payload["device_id"]),
                str(payload["display_name"]),
                str(payload["signing_key_id"]),
                str(payload["signing_public_key_base64"]),
                connection=connection,
            )
            updated = connection.execute(
                """UPDATE pairing_sessions
                   SET consumed_at = ?, paired_device_id = ?
                   WHERE session_id = ? AND consumed_at IS NULL AND revoked_at IS NULL""",
                (_timestamp(now), device["device_id"], row["session_id"]),
            )
            if updated.rowcount != 1:
                raise AccessControlError("配对码已经被其他设备使用")
        return device

    def create_local_pairing_request(
        self,
        payload: dict[str, Any],
        remote_address: str | None,
        owner_id: str = "owner-default",
        lifetime: timedelta = LOCAL_PAIRING_LIFETIME,
    ) -> dict[str, Any]:
        required = {"device_id", "display_name", "signing_key_id", "signing_public_key_base64"}
        missing = required - payload.keys()
        if missing:
            raise AccessControlError(f"缺少字段：{', '.join(sorted(missing))}")
        validate_device_registration(
            owner_id,
            str(payload["device_id"]),
            str(payload["display_name"]),
            str(payload["signing_key_id"]),
            str(payload["signing_public_key_base64"]),
        )

        now = _now()
        request_id = str(uuid.uuid4())
        poll_token = secrets.token_urlsafe(32)
        with self.database.connection() as connection:
            connection.execute(
                """UPDATE local_pairing_requests
                   SET status='superseded', resolved_at=?
                   WHERE device_id=? AND status='pending'""",
                (_timestamp(now), str(payload["device_id"])),
            )
            connection.execute(
                """INSERT INTO local_pairing_requests(
                       request_id, owner_id, poll_token_hash, device_id, display_name,
                       signing_key_id, signing_public_key_base64, remote_address,
                       status, created_at, expires_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)""",
                (
                    request_id,
                    owner_id,
                    _secret_hash(poll_token),
                    str(payload["device_id"]),
                    str(payload["display_name"]),
                    str(payload["signing_key_id"]),
                    str(payload["signing_public_key_base64"]),
                    remote_address,
                    _timestamp(now),
                    _timestamp(now + lifetime),
                ),
            )
        return {
            "request_id": request_id,
            "poll_token": poll_token,
            "status": "pending",
            "created_at": _timestamp(now),
            "expires_at": _timestamp(now + lifetime),
        }

    def local_pairing_request_status(self, request_id: str, poll_token: str) -> dict[str, Any]:
        now = _now()
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM local_pairing_requests WHERE request_id=?",
                (request_id,),
            ).fetchone()
            if row is None or not secrets.compare_digest(
                str(row["poll_token_hash"]), _secret_hash(poll_token)
            ):
                raise AccessControlError("配对请求不存在或凭据无效")
            status = str(row["status"])
            if status == "pending" and _parse_timestamp(str(row["expires_at"])) <= now:
                status = "expired"
                connection.execute(
                    "UPDATE local_pairing_requests SET status='expired', resolved_at=? WHERE request_id=?",
                    (_timestamp(now), request_id),
                )
            return {
                "request_id": request_id,
                "status": status,
                "display_name": str(row["display_name"]),
                "expires_at": str(row["expires_at"]),
            }

    def pending_local_pairing_requests(self) -> list[dict[str, Any]]:
        now = _now()
        with self.database.connection() as connection:
            connection.execute(
                """UPDATE local_pairing_requests SET status='expired', resolved_at=?
                   WHERE status='pending' AND expires_at <= ?""",
                (_timestamp(now), _timestamp(now)),
            )
            rows = connection.execute(
                """SELECT request_id, device_id, display_name, remote_address,
                          created_at, expires_at, status
                   FROM local_pairing_requests
                   WHERE status='pending' ORDER BY created_at DESC"""
            ).fetchall()
        return [dict(row) for row in rows]

    def resolve_local_pairing_request(self, request_id: str, approve: bool) -> dict[str, Any]:
        now = _now()
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM local_pairing_requests WHERE request_id=?",
                (request_id,),
            ).fetchone()
            if row is None or row["status"] != "pending":
                raise AccessControlError("配对请求不存在或已经处理")
            if _parse_timestamp(str(row["expires_at"])) <= now:
                connection.execute(
                    "UPDATE local_pairing_requests SET status='expired', resolved_at=? WHERE request_id=?",
                    (_timestamp(now), request_id),
                )
                raise AccessControlError("配对请求已过期")
            if not approve:
                connection.execute(
                    "UPDATE local_pairing_requests SET status='rejected', resolved_at=? WHERE request_id=?",
                    (_timestamp(now), request_id),
                )
                return {"request_id": request_id, "status": "rejected"}

            device = register_device(
                self.database,
                str(row["owner_id"]),
                str(row["device_id"]),
                str(row["display_name"]),
                str(row["signing_key_id"]),
                str(row["signing_public_key_base64"]),
                connection=connection,
            )
            connection.execute(
                "UPDATE local_pairing_requests SET status='approved', resolved_at=? WHERE request_id=?",
                (_timestamp(now), request_id),
            )
        return {"request_id": request_id, "status": "approved", "device": device}
