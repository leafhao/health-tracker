from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Any

from .dashboard_materializer import DashboardMaterializer, enqueue_snapshot_dependencies
from .database import Database
from .normalizer import normalize_day


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


@dataclass(frozen=True)
class NormalizationResult:
    claimed: int = 0
    completed: int = 0
    failed: int = 0

    def as_dict(self) -> dict[str, int]:
        return {"claimed": self.claimed, "completed": self.completed, "failed": self.failed}


class NormalizationWorker:
    def __init__(self, database: Database, max_attempts: int = 5) -> None:
        self.database = database
        self.max_attempts = max_attempts

    def run_once(self, limit: int = 25) -> NormalizationResult:
        if limit < 1:
            raise ValueError("limit must be at least 1")
        self._recover_stale_jobs()
        claimed = completed = failed = 0
        for _ in range(limit):
            job = self._claim()
            if job is None:
                break
            claimed += 1
            try:
                target_date = date.fromisoformat(job["date"])
                normalize_day(self.database, target_date, job["timezone"])
                enqueue_snapshot_dependencies(
                    self.database,
                    target_date,
                    job["timezone"],
                    reason=f"normalization job {job['id']}",
                )
            except Exception as exc:
                failed += 1
                self._finish(job, error=exc)
            else:
                completed += 1
                self._finish(job)
        materialized = DashboardMaterializer(self.database).run_once(
            limit=max(100, limit * 40)
        )
        if materialized.failed:
            raise RuntimeError(
                f"{materialized.failed} dashboard snapshot job(s) failed"
            )
        return NormalizationResult(claimed, completed, failed)

    def recover_interrupted_jobs(self) -> None:
        """A newly started Receiver cannot have a legitimate running job."""
        with self.database.connection() as connection:
            connection.execute(
                """UPDATE normalization_jobs
                   SET status='pending', started_at=NULL,
                       error_message='receiver restarted during normalization'
                   WHERE status='running'"""
            )

    def ingestion_is_active(self, quiet_seconds: float = 15) -> bool:
        rows = self.database.fetch_all(
            "SELECT MAX(committed_at) AS committed_at FROM ingest_batches WHERE status='committed'"
        )
        value = rows[0]["committed_at"] if rows else None
        if not value:
            return False
        committed_at = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return (datetime.now(UTC) - committed_at).total_seconds() < quiet_seconds

    def _recover_stale_jobs(self) -> None:
        cutoff = (datetime.now(UTC) - timedelta(minutes=30)).isoformat(
            timespec="milliseconds"
        ).replace("+00:00", "Z")
        with self.database.connection() as connection:
            connection.execute(
                """UPDATE normalization_jobs SET status='pending', started_at=NULL,
                          error_message='recovered stale running job'
                   WHERE status='running' AND started_at < ?""",
                (cutoff,),
            )

    def _claim(self) -> dict[str, Any] | None:
        with self.database.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                """SELECT * FROM normalization_jobs
                   WHERE status='pending' ORDER BY created_at, id LIMIT 1"""
            ).fetchone()
            if row is None:
                return None
            started_at = _now()
            connection.execute(
                """UPDATE normalization_jobs
                   SET status='running', attempts=attempts+1, started_at=?, error_message=NULL
                   WHERE id=? AND status='pending'""",
                (started_at, row["id"]),
            )
            output = dict(row)
            output["attempts"] = int(row["attempts"]) + 1
            return output

    def _finish(self, job: dict[str, Any], error: Exception | None = None) -> None:
        now = _now()
        with self.database.connection() as connection:
            if error is None:
                connection.execute(
                    """UPDATE normalization_jobs SET status='completed', completed_at=?
                       WHERE id=? AND status='running'""",
                    (now, job["id"]),
                )
                return
            terminal = int(job["attempts"]) >= self.max_attempts
            connection.execute(
                """UPDATE normalization_jobs SET status=?, started_at=NULL,
                          completed_at=?, error_message=?
                   WHERE id=? AND status='running'""",
                (
                    "failed" if terminal else "pending",
                    now if terminal else None,
                    f"{type(error).__name__}: {error}"[:2000],
                    job["id"],
                ),
            )
