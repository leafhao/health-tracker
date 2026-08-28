from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import re
import tempfile
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat

from .database import Database
from .settings import AppPaths


SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9._:-]{8,128}$")


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def _key_id(public_key: bytes) -> str:
    return "receiver-" + hashlib.sha256(public_key).hexdigest()[:16]


@dataclass(frozen=True)
class ReceiverIdentity:
    key_id: str
    private_key: X25519PrivateKey
    created_at: str
    key_file: Path

    @property
    def public_key_bytes(self) -> bytes:
        return self.private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)

    @property
    def public_key_base64(self) -> str:
        return _b64(self.public_key_bytes)

    def pairing_payload(self, owner_id: str = "owner-default") -> dict[str, Any]:
        fingerprint = hashlib.sha256(self.public_key_bytes).hexdigest()
        return {
            "protocol": "health-pairing/1",
            "owner_id": owner_id,
            "receiver_key_id": self.key_id,
            "receiver_public_key_base64": self.public_key_base64,
            "receiver_fingerprint_sha256": fingerprint,
            "envelope_protocol": "health-envelope/1",
        }


def _atomic_private_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".receiver-key-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_or_create_identity(
    paths: AppPaths, database: Database, owner_id: str = "owner-default"
) -> ReceiverIdentity:
    paths.ensure()
    # Keep the ephemeral lock outside keys/: portable backups intentionally copy
    # only persistent JSON key material from that directory.
    lock_path = paths.root / ".receiver-identity.initialize.lock"
    with lock_path.open("a+b") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            return _load_or_create_identity_unlocked(paths, database, owner_id)
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def _load_or_create_identity_unlocked(
    paths: AppPaths, database: Database, owner_id: str
) -> ReceiverIdentity:
    active = database.fetch_all(
        "SELECT * FROM receiver_keys WHERE is_active = 1 ORDER BY created_at DESC LIMIT 1"
    )
    if active:
        row = active[0]
        key_file = paths.root / row["key_file"]
        payload = json.loads(key_file.read_text(encoding="utf-8"))
        private_key = X25519PrivateKey.from_private_bytes(
            base64.b64decode(payload["private_key_base64"], validate=True)
        )
        identity = ReceiverIdentity(row["key_id"], private_key, row["created_at"], key_file)
        if identity.public_key_base64 != row["public_key_base64"]:
            raise RuntimeError("receiver key file does not match database registry")
        return identity

    private_key = X25519PrivateKey.generate()
    private_bytes = private_key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    public_bytes = private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    key_id = _key_id(public_bytes)
    created_at = _now()
    key_file = paths.keys / f"{key_id}.json"
    _atomic_private_json(
        key_file,
        {
            "algorithm": "HPKE-X25519-HKDF-SHA256-CHACHA20POLY1305",
            "created_at": created_at,
            "key_id": key_id,
            "private_key_base64": _b64(private_bytes),
            "public_key_base64": _b64(public_bytes),
        },
    )
    relative = key_file.relative_to(paths.root).as_posix()
    with database.connection() as connection:
        connection.execute(
            "INSERT OR IGNORE INTO owners(owner_id, display_name, created_at) VALUES (?, ?, ?)",
            (owner_id, "Default Owner", created_at),
        )
        connection.execute(
            """INSERT INTO receiver_keys(
                   key_id, algorithm, public_key_base64, key_file, is_active, created_at
               ) VALUES (?, ?, ?, ?, 1, ?)""",
            (
                key_id,
                "HPKE-X25519-HKDF-SHA256-CHACHA20POLY1305",
                _b64(public_bytes),
                relative,
                created_at,
            ),
        )
    return ReceiverIdentity(key_id, private_key, created_at, key_file)


def register_device(
    database: Database,
    owner_id: str,
    device_id: str,
    display_name: str,
    signing_key_id: str,
    signing_public_key_base64: str,
    connection: sqlite3.Connection | None = None,
) -> dict[str, Any]:
    validate_device_registration(
        owner_id,
        device_id,
        display_name,
        signing_key_id,
        signing_public_key_base64,
    )

    now = _now()
    def write(target: sqlite3.Connection) -> None:
        target.execute(
            "INSERT OR IGNORE INTO owners(owner_id, display_name, created_at) VALUES (?, ?, ?)",
            (owner_id, owner_id, now),
        )
        target.execute(
            """INSERT INTO devices(
                   owner_id, device_id, display_name, signing_key_id,
                   signing_public_key_base64, status, created_at
               ) VALUES (?, ?, ?, ?, ?, 'active', ?)
               ON CONFLICT(owner_id, device_id) DO UPDATE SET
                   display_name=excluded.display_name,
                   signing_key_id=excluded.signing_key_id,
                   signing_public_key_base64=excluded.signing_public_key_base64,
                   status='active'""",
            (
                owner_id,
                device_id,
                display_name,
                signing_key_id,
                signing_public_key_base64,
                now,
            ),
        )
    if connection is None:
        with database.connection() as managed_connection:
            write(managed_connection)
    else:
        write(connection)
    return {
        "owner_id": owner_id,
        "device_id": device_id,
        "display_name": display_name,
        "signing_key_id": signing_key_id,
        "status": "active",
    }


def validate_device_registration(
    owner_id: str,
    device_id: str,
    display_name: str,
    signing_key_id: str,
    signing_public_key_base64: str,
) -> None:
    for label, value in (
        ("owner_id", owner_id),
        ("device_id", device_id),
        ("signing_key_id", signing_key_id),
    ):
        if not SAFE_IDENTIFIER.fullmatch(value):
            raise ValueError(f"{label} must be 8-128 safe identifier characters")
    if not display_name.strip() or len(display_name) > 128:
        raise ValueError("display_name must contain 1-128 characters")
    try:
        public_key = base64.b64decode(signing_public_key_base64, validate=True)
    except Exception as exc:
        raise ValueError("invalid signing public key base64") from exc
    if len(public_key) != 32:
        raise ValueError("Ed25519 public key must be 32 bytes")
