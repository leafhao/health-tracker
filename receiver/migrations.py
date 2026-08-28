from __future__ import annotations

import hashlib
import sqlite3
from datetime import UTC, datetime
from pathlib import Path


class MigrationError(RuntimeError):
    pass


def apply_migrations(connection: sqlite3.Connection, directory: Path | None = None) -> None:
    migration_dir = directory or Path(__file__).with_name("migrations")
    connection.execute(
        """CREATE TABLE IF NOT EXISTS schema_migrations (
               name TEXT PRIMARY KEY,
               sha256 TEXT NOT NULL,
               applied_at TEXT NOT NULL
           )"""
    )
    applied = {
        row["name"]: row["sha256"]
        for row in connection.execute("SELECT name, sha256 FROM schema_migrations")
    }
    for path in sorted(migration_dir.glob("*.sql")):
        body = path.read_bytes()
        checksum = hashlib.sha256(body).hexdigest()
        if path.name in applied:
            if applied[path.name] != checksum:
                raise MigrationError(f"applied migration changed: {path.name}")
            continue
        connection.executescript(body.decode("utf-8"))
        connection.execute(
            "INSERT INTO schema_migrations(name, sha256, applied_at) VALUES (?, ?, ?)",
            (path.name, checksum, datetime.now(UTC).isoformat()),
        )
