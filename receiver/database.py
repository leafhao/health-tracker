from __future__ import annotations

import json
import fcntl
import sqlite3
from collections.abc import Iterable, Sequence
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .models import WireModel
from .migrations import apply_migrations


DATE_FIELDS = {"start_date", "end_date"}
ALLOWED_RECONCILE_TABLES = {
    "quantity_samples": {"type"},
    "category_samples": {"type"},
    "workouts": set(),
    "workout_routes": set(),
}
WIRE_TABLES = {
    "quantity_samples": "quantity_samples",
    "category_samples": "category_samples",
    "workouts": "workouts",
    "workout_routes": "workout_routes",
    "activity_summaries": "activity_summaries",
}


def normalize_timestamp(value: str) -> str:
    """Accept HealthBeat SQL dates or ISO-8601 and store canonical UTC."""
    candidate = value.strip()
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError as exc:
        raise ValueError(f"invalid timestamp: {value}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class Database:
    def __init__(self, path: str | Path, schema_path: str | Path | None = None) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.schema_path = Path(schema_path or Path(__file__).with_name("schema.sql"))
        self.initialize()

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        return connection

    @contextmanager
    def connection(self):
        """Yield a transactional connection and always release its file handle."""
        connection = self.connect()
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def initialize(self) -> None:
        # API and both workers can be started together by launchd/systemd. SQLite
        # transactions alone do not serialize executescript(), which may commit
        # between migration statements, so guard the complete bootstrap with a
        # host-local advisory lock.
        lock_path = self.path.with_name(f"{self.path.name}.initialize.lock")
        with lock_path.open("a+b") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                with self.connection() as connection:
                    connection.executescript(self.schema_path.read_text(encoding="utf-8"))
                    apply_migrations(connection)
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

    def upsert(self, table: str, records: Sequence[WireModel], remote_address: str | None) -> int:
        if table not in WIRE_TABLES:
            raise ValueError(f"unsupported table: {table}")
        if not records:
            self._log_ingest(table, 0, 0, remote_address)
            return 0

        rows = [self._wire_row(record) for record in records]
        columns = list(rows[0])
        placeholders = ", ".join("?" for _ in columns)
        column_sql = ", ".join(columns)
        conflict_key = "date" if table == "activity_summaries" else "uuid"
        updates = ", ".join(
            f"{column}=excluded.{column}" for column in columns if column != conflict_key
        )
        sql = (
            f"INSERT INTO {table} ({column_sql}) VALUES ({placeholders}) "
            f"ON CONFLICT({conflict_key}) DO UPDATE SET {updates}"
        )

        with self.connection() as connection:
            connection.executemany(sql, [[row[column] for column in columns] for row in rows])
            connection.execute(
                "INSERT INTO ingest_log(endpoint, accepted, rejected, remote_address) VALUES (?, ?, 0, ?)",
                (table, len(rows), remote_address),
            )
        return len(rows)

    def _log_ingest(self, endpoint: str, accepted: int, rejected: int, remote_address: str | None) -> None:
        with self.connection() as connection:
            connection.execute(
                "INSERT INTO ingest_log(endpoint, accepted, rejected, remote_address) VALUES (?, ?, ?, ?)",
                (endpoint, accepted, rejected, remote_address),
            )

    @staticmethod
    def _wire_row(record: WireModel) -> dict[str, Any]:
        row = record.model_dump()
        for field in DATE_FIELDS & row.keys():
            row[field] = normalize_timestamp(row[field])
        return row

    def reconcile(
        self,
        table: str,
        type_column: str | None,
        type_value: str | None,
        since: str,
        until: str,
        valid_uuids: Iterable[str],
    ) -> int:
        # Accept legacy HealthBeat/EA names while keeping SQL identifiers fixed.
        table = table.removeprefix("hb_").removeprefix("health_")
        allowed_columns = ALLOWED_RECONCILE_TABLES.get(table)
        if allowed_columns is None:
            raise ValueError("table is not reconcilable")
        if type_column and type_column not in allowed_columns:
            raise ValueError("type column is not allowed for this table")
        if bool(type_column) != bool(type_value):
            raise ValueError("type_column and type_value must be supplied together")

        clauses = ["start_date >= ?", "start_date < ?"]
        parameters: list[Any] = [normalize_timestamp(since), normalize_timestamp(until)]
        if type_column:
            clauses.append(f"{type_column} = ?")
            parameters.append(type_value)
        uuids = list(dict.fromkeys(valid_uuids))
        if uuids:
            clauses.append(f"uuid NOT IN ({', '.join('?' for _ in uuids)})")
            parameters.extend(uuids)

        with self.connection() as connection:
            cursor = connection.execute(
                f"DELETE FROM {table} WHERE {' AND '.join(clauses)}",
                parameters,
            )
            return cursor.rowcount

    def fetch_all(self, sql: str, parameters: Sequence[Any] = ()) -> list[dict[str, Any]]:
        with self.connection() as connection:
            return [dict(row) for row in connection.execute(sql, parameters).fetchall()]

    def count(self, table: str) -> int:
        if table not in WIRE_TABLES:
            raise ValueError("unsupported table")
        with self.connection() as connection:
            return int(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])


def decode_json_columns(record: dict[str, Any]) -> dict[str, Any]:
    output = dict(record)
    for key in ("metadata", "locations_json"):
        raw = output.get(key)
        if isinstance(raw, str):
            try:
                output[key.removesuffix("_json")] = json.loads(raw)
            except json.JSONDecodeError:
                pass
    return output
