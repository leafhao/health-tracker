from __future__ import annotations

import base64
import hashlib
import json
from datetime import UTC, datetime
from typing import Any, Mapping
from zoneinfo import ZoneInfo

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from .database import Database, normalize_timestamp
from .identity import ReceiverIdentity
from .models import (
    ActivitySummary,
    CategorySample,
    DeviceCapabilities,
    QuantitySample,
    Workout,
    WorkoutRoute,
)
from .sync_crypto import EnvelopeError, encode_payload, open_envelope, peek_header


ENTITY_MODELS = {
    "quantity": ("quantity_samples", QuantitySample, "uuid"),
    "category": ("category_samples", CategorySample, "uuid"),
    "workout": ("workouts", Workout, "uuid"),
    "workout_route": ("workout_routes", WorkoutRoute, "uuid"),
    "activity_summary": ("activity_summaries", ActivitySummary, "date"),
    "device_capabilities": ("device_capabilities", DeviceCapabilities, "device_id"),
}


class IngestionError(ValueError):
    pass


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _canonical(value: Mapping[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _upsert(connection, table: str, row: dict[str, Any], conflict_key: str) -> None:
    columns = list(row)
    updates = ", ".join(
        f"{column}=excluded.{column}" for column in columns if column != conflict_key
    )
    connection.execute(
        f"""INSERT INTO {table} ({', '.join(columns)})
            VALUES ({', '.join('?' for _ in columns)})
            ON CONFLICT({conflict_key}) DO UPDATE SET {updates}""",
        [row[column] for column in columns],
    )


def _validated_typed_row(entity_type: str, source_uuid: str, payload: Any) -> tuple[str, dict[str, Any], str]:
    descriptor = ENTITY_MODELS.get(entity_type)
    if descriptor is None:
        raise IngestionError(f"unsupported entity_type: {entity_type}")
    if not isinstance(payload, dict):
        raise IngestionError("upsert event payload must be an object")
    table, model_type, conflict_key = descriptor
    try:
        record = model_type.model_validate(payload)
    except Exception as exc:
        raise IngestionError(f"invalid {entity_type} payload: {exc}") from exc
    row = record.model_dump()
    for field in ("start_date", "end_date", "reported_at"):
        if field in row:
            row[field] = normalize_timestamp(row[field])
    expected = row[conflict_key]
    if str(expected) != source_uuid:
        raise IngestionError(f"source_uuid does not match payload {conflict_key}")
    return table, row, conflict_key


def _route_points(connection, owner_id: str, row: dict[str, Any]) -> None:
    connection.execute(
        "DELETE FROM route_points WHERE owner_id = ? AND route_uuid = ?",
        (owner_id, row["uuid"]),
    )
    raw = row.get("locations_json")
    if not raw:
        return
    try:
        locations = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise IngestionError("workout route locations_json is invalid") from exc
    if not isinstance(locations, list):
        raise IngestionError("workout route locations_json must be an array")
    for index, point in enumerate(locations):
        if not isinstance(point, dict) or "latitude" not in point or "longitude" not in point:
            raise IngestionError("workout route point is invalid")
        connection.execute(
            """INSERT INTO route_points(
                   owner_id, route_uuid, workout_uuid, point_index, timestamp,
                   latitude, longitude, altitude, horizontal_accuracy,
                   vertical_accuracy, speed, course
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                owner_id,
                row["uuid"],
                row["workout_uuid"],
                index,
                normalize_timestamp(str(point.get("timestamp") or row["start_date"])),
                float(point["latitude"]),
                float(point["longitude"]),
                point.get("altitude"),
                point.get("horizontal_accuracy"),
                point.get("vertical_accuracy"),
                point.get("speed"),
                point.get("course"),
            ),
        )


def _delete_typed(connection, owner_id: str, entity_type: str, source_uuid: str) -> None:
    descriptor = ENTITY_MODELS.get(entity_type)
    if descriptor is None:
        raise IngestionError(f"unsupported entity_type: {entity_type}")
    table, _, conflict_key = descriptor
    if entity_type == "workout_route":
        connection.execute(
            "DELETE FROM route_points WHERE owner_id = ? AND route_uuid = ?",
            (owner_id, source_uuid),
        )
    elif entity_type == "workout":
        connection.execute(
            "DELETE FROM route_points WHERE owner_id = ? AND workout_uuid = ?",
            (owner_id, source_uuid),
        )
    connection.execute(f"DELETE FROM {table} WHERE {conflict_key} = ?", (source_uuid,))


def _affected_dates(entity_type: str, payload: Any, timezone_name: str) -> set[str]:
    if not isinstance(payload, dict):
        return set()
    if entity_type == "activity_summary" and payload.get("date"):
        return {str(payload["date"])}
    timezone = ZoneInfo(timezone_name)
    dates: set[str] = set()
    for field in ("start_date", "end_date"):
        value = payload.get(field)
        if not value:
            continue
        parsed = datetime.fromisoformat(normalize_timestamp(str(value)).replace("Z", "+00:00"))
        dates.add(parsed.astimezone(timezone).date().isoformat())
    return dates


def _validate_batch(payload: Mapping[str, Any], header: Mapping[str, Any]) -> list[dict[str, Any]]:
    required = {
        "schema_version",
        "batch_id",
        "owner_id",
        "device_id",
        "stream_id",
        "sequence",
        "created_at",
        "events",
    }
    missing = required - payload.keys()
    if missing:
        raise IngestionError(f"missing batch fields: {', '.join(sorted(missing))}")
    if payload["schema_version"] != 1:
        raise IngestionError("unsupported event batch schema")
    for field in ("batch_id", "device_id", "sequence", "created_at"):
        if payload[field] != header[field]:
            raise IngestionError(f"batch {field} does not match signed header")
    events = payload["events"]
    if not isinstance(events, list) or not 1 <= len(events) <= 1000:
        raise IngestionError("events must contain 1 to 1000 items")
    event_ids: set[str] = set()
    for event in events:
        if not isinstance(event, dict):
            raise IngestionError("event must be an object")
        missing_event = {
            "event_id",
            "operation",
            "entity_type",
            "source_uuid",
            "observed_at",
        } - event.keys()
        if missing_event:
            raise IngestionError(f"missing event fields: {', '.join(sorted(missing_event))}")
        if event["operation"] not in {"upsert", "delete"}:
            raise IngestionError("unsupported event operation")
        if event["event_id"] in event_ids:
            raise IngestionError("duplicate event_id inside batch")
        event_ids.add(event["event_id"])
        if event["operation"] == "upsert":
            _validated_typed_row(
                str(event["entity_type"]), str(event["source_uuid"]), event.get("payload")
            )
    return events


class BatchIngestionService:
    def __init__(
        self,
        database: Database,
        identity: ReceiverIdentity,
        timezone_name: str = "Asia/Shanghai",
    ) -> None:
        self.database = database
        self.identity = identity
        self.timezone_name = timezone_name

    def ingest(
        self, envelope: Mapping[str, Any], object_key: str | None = None
    ) -> dict[str, Any]:
        opened, device = self.open_authenticated_envelope(envelope)
        payload = opened.payload
        events = _validate_batch(payload, opened.header)
        if payload["owner_id"] != device["owner_id"]:
            raise IngestionError("batch owner does not match registered device")
        envelope_sha256 = hashlib.sha256(encode_payload(envelope)).hexdigest()
        owner_id = device["owner_id"]
        device_id = device["device_id"]
        batch_id = str(payload["batch_id"])
        sequence = int(payload["sequence"])
        now = _now()

        existing = self.database.fetch_all(
            """SELECT receipt_json, envelope_sha256 FROM ingest_batches
               LEFT JOIN sync_receipts USING(owner_id, device_id, batch_id)
               WHERE owner_id = ? AND device_id = ? AND batch_id = ?""",
            (owner_id, device_id, batch_id),
        )
        if existing:
            if existing[0]["envelope_sha256"] != envelope_sha256:
                raise IngestionError("batch_id was reused with different ciphertext")
            if existing[0].get("receipt_json"):
                receipt = json.loads(existing[0]["receipt_json"])
                receipt["duplicate"] = True
                return receipt
            raise IngestionError("batch exists without a committed receipt")

        accepted = 0
        rejected = 0
        affected_dates: set[str] = set()
        with self.database.connection() as connection:
            sequence_conflict = connection.execute(
                """SELECT batch_id FROM ingest_batches
                   WHERE owner_id = ? AND device_id = ? AND sequence = ?""",
                (owner_id, device_id, sequence),
            ).fetchone()
            if sequence_conflict:
                raise IngestionError("device sequence was reused by another batch")
            previous = connection.execute(
                """SELECT batch_id FROM ingest_batches
                   WHERE owner_id = ? AND device_id = ? AND sequence = ?""",
                (owner_id, device_id, sequence - 1),
            ).fetchone()
            expected_previous = payload.get("previous_batch_id")
            gap_detected = sequence > 1 and (
                previous is None or str(previous["batch_id"]) != str(expected_previous)
            )
            connection.execute(
                """INSERT INTO ingest_batches(
                       owner_id, device_id, batch_id, sequence, stream_id,
                       previous_batch_id, object_key, envelope_sha256, status,
                       event_count, created_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'verified', ?, ?)""",
                (
                    owner_id,
                    device_id,
                    batch_id,
                    sequence,
                    payload["stream_id"],
                    expected_previous,
                    object_key,
                    envelope_sha256,
                    len(events),
                    normalize_timestamp(payload["created_at"]),
                ),
            )
            for event in events:
                event_json = _canonical(event)
                previous_event = connection.execute(
                    "SELECT * FROM raw_events WHERE event_id = ?", (event["event_id"],)
                ).fetchone()
                if previous_event:
                    previous_payload = previous_event["payload_json"]
                    if (
                        previous_event["operation"] != event["operation"]
                        or previous_event["entity_type"] != event["entity_type"]
                        or previous_event["source_uuid"] != event["source_uuid"]
                        or previous_payload != (
                            _canonical(event["payload"]) if event.get("payload") is not None else None
                        )
                    ):
                        raise IngestionError("event_id was reused with different content")
                    continue
                payload_json = (
                    _canonical(event["payload"]) if event.get("payload") is not None else None
                )
                connection.execute(
                    """INSERT INTO raw_events(
                           event_id, owner_id, device_id, batch_id, stream_id,
                           sequence, operation, entity_type, source_uuid,
                           observed_at, payload_json, ingested_at
                       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        event["event_id"], owner_id, device_id, batch_id,
                        payload["stream_id"], sequence, event["operation"],
                        event["entity_type"], event["source_uuid"],
                        normalize_timestamp(event["observed_at"]), payload_json, now,
                    ),
                )
                if event["operation"] == "upsert":
                    table, row, conflict_key = _validated_typed_row(
                        event["entity_type"], event["source_uuid"], event["payload"]
                    )
                    _upsert(connection, table, row, conflict_key)
                    if event["entity_type"] == "workout_route":
                        _route_points(connection, owner_id, row)
                    affected_dates.update(
                        _affected_dates(event["entity_type"], event["payload"], self.timezone_name)
                    )
                else:
                    _delete_typed(connection, owner_id, event["entity_type"], event["source_uuid"])
                    connection.execute(
                        """INSERT INTO tombstones(
                               owner_id, entity_type, source_uuid, event_id,
                               deleted_at, device_id
                           ) VALUES (?, ?, ?, ?, ?, ?)
                           ON CONFLICT(owner_id, entity_type, source_uuid) DO UPDATE SET
                               event_id=excluded.event_id,
                               deleted_at=excluded.deleted_at,
                               device_id=excluded.device_id""",
                        (owner_id, event["entity_type"], event["source_uuid"],
                         event["event_id"], normalize_timestamp(event["observed_at"]), device_id),
                    )
                accepted += 1
            for target_date in affected_dates:
                connection.execute(
                    """INSERT INTO normalization_jobs(
                           owner_id, date, timezone, reason, status, created_at
                       ) VALUES (?, ?, ?, ?, 'pending', ?)
                       ON CONFLICT(owner_id, date, timezone) DO UPDATE SET
                           reason=excluded.reason, status='pending', attempts=0,
                           created_at=excluded.created_at, started_at=NULL,
                           completed_at=NULL, error_message=NULL""",
                    (owner_id, target_date, self.timezone_name, f"batch:{batch_id}", now),
                )
            receipt = {
                "protocol": "health-receipt/1", "owner_id": owner_id,
                "device_id": device_id, "batch_id": batch_id, "sequence": sequence,
                "status": "committed", "committed_at": now, "accepted": accepted,
                "rejected": rejected, "gap_detected": gap_detected, "duplicate": False,
            }
            receipt_json = _canonical(receipt)
            connection.execute(
                """UPDATE ingest_batches SET status='committed', accepted_count=?,
                       rejected_count=?, gap_detected=?, committed_at=?
                   WHERE owner_id=? AND device_id=? AND batch_id=?""",
                (accepted, rejected, int(gap_detected), now, owner_id, device_id, batch_id),
            )
            connection.execute(
                """INSERT INTO sync_receipts(
                       owner_id, device_id, batch_id, sequence, status,
                       accepted, rejected, gap_detected, committed_at, receipt_json
                   ) VALUES (?, ?, ?, ?, 'committed', ?, ?, ?, ?, ?)""",
                (owner_id, device_id, batch_id, sequence, accepted, rejected,
                 int(gap_detected), now, receipt_json),
            )
            connection.execute(
                """UPDATE devices SET last_sequence = MAX(last_sequence, ?), last_seen_at = ?
                   WHERE owner_id = ? AND device_id = ?""",
                (sequence, now, owner_id, device_id),
            )
        return receipt

    def open_authenticated_envelope(
        self,
        envelope: Mapping[str, Any],
        expected_content_type: str | None = None,
    ):
        try:
            header = peek_header(envelope)
        except EnvelopeError as exc:
            raise IngestionError(str(exc)) from exc
        if header["receiver_key_id"] != self.identity.key_id:
            raise IngestionError("envelope targets an unknown receiver key")
        devices = self.database.fetch_all(
            "SELECT * FROM devices WHERE device_id = ? AND status = 'active'",
            (header["device_id"],),
        )
        if len(devices) != 1:
            raise IngestionError("device is not registered or is disabled")
        device = devices[0]
        if header["signing_key_id"] != device["signing_key_id"]:
            raise IngestionError("unknown device signing key")
        try:
            signing_key = Ed25519PublicKey.from_public_bytes(
                base64.b64decode(device["signing_public_key_base64"], validate=True)
            )
            opened = open_envelope(envelope, self.identity.private_key, signing_key)
        except Exception as exc:
            raise IngestionError(str(exc)) from exc
        if expected_content_type is not None and opened.header["content_type"] != expected_content_type:
            raise IngestionError("unexpected envelope content type")
        return opened, device
