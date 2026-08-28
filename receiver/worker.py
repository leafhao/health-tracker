from __future__ import annotations

import argparse
import os
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .cloud_relay import CloudRelayWorker
from .database import Database
from .identity import load_or_create_identity
from .normalization_worker import NormalizationWorker
from .settings import AppPaths
from .v2_ingestion import BatchIngestionService


NORMALIZATION_WORKER = "normalization"
CLOUD_RELAY_WORKER = "cloud-relay"


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def update_worker_heartbeat(
    database: Database,
    worker_name: str,
    status: str,
    *,
    success: bool = False,
    error: Exception | str | None = None,
) -> None:
    now = _now()
    message = None if error is None else str(error)[:2000]
    with database.connection() as connection:
        connection.execute(
            """INSERT INTO worker_heartbeats(
                   worker_name, pid, status, last_heartbeat_at,
                   last_success_at, last_error
               ) VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT(worker_name) DO UPDATE SET
                   pid=excluded.pid,
                   status=excluded.status,
                   last_heartbeat_at=excluded.last_heartbeat_at,
                   last_success_at=CASE
                       WHEN excluded.last_success_at IS NOT NULL
                           THEN excluded.last_success_at
                       ELSE worker_heartbeats.last_success_at
                   END,
                   last_error=excluded.last_error""",
            (
                worker_name,
                os.getpid(),
                status,
                now,
                now if success else None,
                message,
            ),
        )


def worker_heartbeat(database: Database, worker_name: str) -> dict[str, Any] | None:
    rows = database.fetch_all(
        "SELECT * FROM worker_heartbeats WHERE worker_name = ?",
        (worker_name,),
    )
    return rows[0] if rows else None


def heartbeat_age_seconds(row: dict[str, Any] | None) -> float | None:
    if not row or not row.get("last_heartbeat_at"):
        return None
    updated = datetime.fromisoformat(str(row["last_heartbeat_at"]).replace("Z", "+00:00"))
    return max(0.0, (datetime.now(UTC) - updated).total_seconds())


def run_normalization_loop(database: Database, limit: int = 10) -> None:
    worker = NormalizationWorker(database)
    worker.recover_interrupted_jobs()
    while True:
        try:
            if worker.ingestion_is_active(quiet_seconds=15):
                update_worker_heartbeat(database, NORMALIZATION_WORKER, "waiting-for-ingest")
                time.sleep(2)
                continue
            update_worker_heartbeat(database, NORMALIZATION_WORKER, "running")
            result = worker.run_once(limit)
            update_worker_heartbeat(
                database,
                NORMALIZATION_WORKER,
                "idle" if result.claimed == 0 else "running",
                success=True,
            )
            time.sleep(0.5 if result.claimed else 2)
        except KeyboardInterrupt:
            update_worker_heartbeat(database, NORMALIZATION_WORKER, "stopped")
            return
        except Exception as exc:
            update_worker_heartbeat(
                database,
                NORMALIZATION_WORKER,
                "error",
                error=exc,
            )
            time.sleep(5)


def run_cloud_relay_loop(paths: AppPaths, database: Database, limit: int = 10) -> None:
    identity = load_or_create_identity(paths, database)
    ingestion = BatchIngestionService(database, identity)
    worker = CloudRelayWorker(paths, database, ingestion)
    disabled = os.environ.get("HEALTH_RECEIVER_DISABLE_CLOUD_RELAY") == "1"
    while True:
        try:
            if disabled:
                update_worker_heartbeat(database, CLOUD_RELAY_WORKER, "disabled", success=True)
                time.sleep(60)
                continue
            update_worker_heartbeat(database, CLOUD_RELAY_WORKER, "polling")
            worker.poll_once(limit)
            update_worker_heartbeat(
                database,
                CLOUD_RELAY_WORKER,
                "idle",
                success=True,
            )
            time.sleep(30)
        except KeyboardInterrupt:
            update_worker_heartbeat(database, CLOUD_RELAY_WORKER, "stopped")
            return
        except Exception as exc:
            update_worker_heartbeat(
                database,
                CLOUD_RELAY_WORKER,
                "error",
                error=exc,
            )
            time.sleep(90)


def main() -> None:
    parser = argparse.ArgumentParser(description="HealthTracker background workers")
    parser.add_argument("worker", choices=(NORMALIZATION_WORKER, CLOUD_RELAY_WORKER))
    parser.add_argument(
        "--data-root",
        type=Path,
        default=Path(os.environ.get("HEALTH_TRACKER_HOME", "receiver/data")),
    )
    parser.add_argument("--database", type=Path, default=None)
    parser.add_argument("--limit", type=int, default=10)
    args = parser.parse_args()
    paths = AppPaths(args.data_root.expanduser().resolve())
    paths.ensure()
    database = Database((args.database or paths.database).expanduser().resolve())
    if args.worker == NORMALIZATION_WORKER:
        run_normalization_loop(database, args.limit)
    else:
        run_cloud_relay_loop(paths, database, args.limit)


if __name__ == "__main__":
    main()
