from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Any

from .database import Database
from .normalizer import (
    BODY_FAT_PERCENTAGE,
    BODY_MASS,
    BODY_MASS_INDEX,
    HEART_RATE,
    HEART_RATE_RECOVERY,
    HRV,
    LEAN_BODY_MASS,
    OXYGEN_SATURATION,
    RESPIRATORY_RATE,
    RESTING_HEART_RATE,
    SLEEPING_WRIST_TEMPERATURE,
    VO2_MAX,
)


AVAILABILITY_SNAPSHOT = "data-availability-v2"
INSIGHT_DEPENDENCY_DAYS = 34


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _decode_sources(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if not row:
        return row
    output = dict(row)
    raw = output.pop("sources_json", None)
    if isinstance(raw, str):
        try:
            output["sources"] = json.loads(raw)
        except json.JSONDecodeError:
            output["sources"] = {}
    return output


def _availability_revision(database: Database) -> str:
    row = database.fetch_all(
        """SELECT
               COALESCE((SELECT MAX(committed_at) FROM ingest_batches WHERE status='committed'), '')
                   AS batches_revision,
               COALESCE((SELECT MAX(reported_at) FROM device_capabilities), '')
                   AS capabilities_revision,
               COALESCE((SELECT MAX(received_at) FROM quantity_samples), '')
                   AS quantities_revision"""
    )[0]
    return "|".join(
        str(row[key] or "")
        for key in (
            "batches_revision",
            "capabilities_revision",
            "quantities_revision",
        )
    )


def build_data_availability(database: Database) -> dict[str, Any]:
    tracked = {
        "heart_rate": HEART_RATE,
        "resting_heart_rate": RESTING_HEART_RATE,
        "hrv": HRV,
        "oxygen_saturation": OXYGEN_SATURATION,
        "respiratory_rate": RESPIRATORY_RATE,
        "vo2_max": VO2_MAX,
        "heart_rate_recovery": HEART_RATE_RECOVERY,
        "sleeping_wrist_temperature": SLEEPING_WRIST_TEMPERATURE,
        "body_mass": BODY_MASS,
        "body_fat_percentage": BODY_FAT_PERCENTAGE,
        "body_mass_index": BODY_MASS_INDEX,
        "lean_body_mass": LEAN_BODY_MASS,
    }
    placeholders = ", ".join("?" for _ in tracked)
    rows = database.fetch_all(
        f"""SELECT type, COUNT(*) AS records, MIN(start_date) AS first_sample,
                    MAX(end_date) AS last_sample
             FROM quantity_samples WHERE type IN ({placeholders}) GROUP BY type""",
        tuple(tracked.values()),
    )
    by_type = {row["type"]: row for row in rows}
    reports = database.fetch_all(
        """SELECT device_id, app_version, platform_version, health_data_available,
                  health_permissions_requested, supported_quantity_types_json,
                  supported_domains_json, reported_at
           FROM device_capabilities ORDER BY reported_at DESC"""
    )
    decoded_reports: list[dict[str, Any]] = []
    supported_union: set[str] = set()
    for report in reports:
        item = dict(report)
        for source, target in (
            ("supported_quantity_types_json", "supported_quantity_types"),
            ("supported_domains_json", "supported_domains"),
        ):
            raw = item.pop(source, "[]")
            try:
                item[target] = json.loads(raw)
            except (TypeError, json.JSONDecodeError):
                item[target] = []
        supported_union.update(item["supported_quantity_types"])
        decoded_reports.append(item)
    permissions_requested = any(
        bool(item["health_permissions_requested"]) for item in decoded_reports
    )
    output: dict[str, Any] = {}
    for key, type_id in tracked.items():
        item = dict(
            by_type.get(
                type_id,
                {"records": 0, "first_sample": None, "last_sample": None},
            )
        )
        item["support_status"] = (
            "unknown"
            if not decoded_reports
            else ("supported" if type_id in supported_union else "unsupported")
        )
        item["permissions_requested"] = permissions_requested
        output[key] = item
    output["device_reports"] = decoded_reports
    return output


def load_data_availability(database: Database) -> dict[str, Any]:
    rows = database.fetch_all(
        "SELECT payload_json FROM dashboard_global_snapshots WHERE name = ?",
        (AVAILABILITY_SNAPSHOT,),
    )
    if rows:
        try:
            return json.loads(rows[0]["payload_json"])
        except (TypeError, json.JSONDecodeError):
            pass
    return refresh_data_availability(database, force=True)


def refresh_data_availability(database: Database, force: bool = False) -> dict[str, Any]:
    revision = _availability_revision(database)
    rows = database.fetch_all(
        """SELECT payload_json, source_revision FROM dashboard_global_snapshots
           WHERE name = ?""",
        (AVAILABILITY_SNAPSHOT,),
    )
    if rows and not force and rows[0]["source_revision"] == revision:
        try:
            return json.loads(rows[0]["payload_json"])
        except (TypeError, json.JSONDecodeError):
            pass
    payload = build_data_availability(database)
    with database.connection() as connection:
        connection.execute(
            """INSERT INTO dashboard_global_snapshots(
                   name, payload_json, source_revision, materialized_at
               ) VALUES (?, ?, ?, ?)
               ON CONFLICT(name) DO UPDATE SET
                   payload_json=excluded.payload_json,
                   source_revision=excluded.source_revision,
                   materialized_at=excluded.materialized_at""",
            (AVAILABILITY_SNAPSHOT, _canonical(payload), revision, _now()),
        )
    return payload


def build_day_snapshot(
    database: Database,
    target_date: date,
    timezone_name: str = "Asia/Shanghai",
) -> tuple[dict[str, Any], str] | None:
    run_rows = database.fetch_all(
        """SELECT normalized_at FROM normalization_runs
           WHERE timezone = ? AND date = ?""",
        (timezone_name, target_date.isoformat()),
    )
    if not run_rows:
        return None
    daily_rows = database.fetch_all(
        "SELECT * FROM normalized_daily_summaries WHERE timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    sleep_rows = database.fetch_all(
        "SELECT * FROM normalized_sleep_summaries WHERE timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    training_rows = database.fetch_all(
        "SELECT * FROM normalized_training_summaries WHERE timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    workout_rows = database.fetch_all(
        """SELECT * FROM normalized_workouts
           WHERE timezone = ? AND date = ? ORDER BY start_date""",
        (timezone_name, target_date.isoformat()),
    )
    for workout in workout_rows:
        raw_preview = workout.pop("route_preview_json", "[]")
        raw_zones = workout.pop("heart_rate_zones_json", "{}")
        try:
            workout["route_preview"] = json.loads(raw_preview) if raw_preview else []
        except (TypeError, json.JSONDecodeError):
            workout["route_preview"] = []
        try:
            workout["heart_rate_zones"] = json.loads(raw_zones) if raw_zones else {}
        except (TypeError, json.JSONDecodeError):
            workout["heart_rate_zones"] = {}
    minute_rows = database.fetch_all(
        """SELECT minute, type, value, min_value, max_value, sample_count, unit, source_name
           FROM normalized_quantity_minutes
           WHERE timezone = ? AND date = ? AND type = ? ORDER BY minute""",
        (timezone_name, target_date.isoformat(), HEART_RATE),
    )
    sleep_window = sleep_rows[0] if sleep_rows else None
    sleep_segments: list[dict[str, Any]] = []
    if sleep_window:
        raw_segments = sleep_window.pop("segments_json", "[]")
        try:
            sleep_segments = json.loads(raw_segments) if raw_segments else []
        except (TypeError, json.JSONDecodeError):
            sleep_segments = []
    daily_row = daily_rows[0] if daily_rows else None
    decoded_sleep = _decode_sources(sleep_window)
    training_row = training_rows[0] if training_rows else None
    # Imported lazily so dashboard.py can use this module without an import cycle.
    from .dashboard import _dashboard_insights

    payload = {
        "date": target_date.isoformat(),
        "timezone": timezone_name,
        "daily": daily_row,
        "sleep": decoded_sleep,
        "sleep_segments": sleep_segments,
        "workouts": workout_rows,
        "training": training_row,
        "heart_rate": minute_rows,
        "quantity_minutes": minute_rows,
        "insights": _dashboard_insights(
            database,
            target_date,
            timezone_name,
            daily_row,
            decoded_sleep,
            training_row,
        ),
    }
    return payload, str(run_rows[0]["normalized_at"])


def load_day_snapshot(
    database: Database,
    target_date: date,
    timezone_name: str = "Asia/Shanghai",
) -> dict[str, Any] | None:
    rows = database.fetch_all(
        """SELECT payload_json FROM dashboard_day_snapshots
           WHERE timezone = ? AND date = ?""",
        (timezone_name, target_date.isoformat()),
    )
    if not rows:
        return None
    try:
        return json.loads(rows[0]["payload_json"])
    except (TypeError, json.JSONDecodeError):
        return None


def enqueue_snapshot_dependencies(
    database: Database,
    target_date: date,
    timezone_name: str = "Asia/Shanghai",
    reason: str = "normalized dependency changed",
) -> None:
    end = target_date + timedelta(days=INSIGHT_DEPENDENCY_DAYS)
    normalized = database.fetch_all(
        """SELECT date FROM normalization_runs
           WHERE timezone = ? AND date >= ? AND date <= ? ORDER BY date""",
        (timezone_name, target_date.isoformat(), end.isoformat()),
    )
    now = _now()
    with database.connection() as connection:
        connection.executemany(
            """INSERT INTO dashboard_snapshot_jobs(timezone, date, reason, created_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(timezone, date) DO UPDATE SET
                   reason=excluded.reason, created_at=excluded.created_at""",
            [
                (timezone_name, row["date"], reason, now)
                for row in normalized
            ],
        )


@dataclass(frozen=True)
class MaterializationResult:
    queued: int = 0
    completed: int = 0
    failed: int = 0


class DashboardMaterializer:
    def __init__(self, database: Database) -> None:
        self.database = database

    def ensure_backfill(self) -> int:
        now = _now()
        with self.database.connection() as connection:
            before = connection.total_changes
            connection.execute(
                """INSERT OR IGNORE INTO dashboard_snapshot_jobs(
                       timezone, date, reason, created_at
                   )
                   SELECT runs.timezone, runs.date, 'snapshot missing or stale', ?
                   FROM normalization_runs AS runs
                   LEFT JOIN dashboard_day_snapshots AS snapshots
                     ON snapshots.timezone = runs.timezone AND snapshots.date = runs.date
                   WHERE snapshots.date IS NULL
                      OR snapshots.source_normalized_at <> runs.normalized_at""",
                (now,),
            )
            return connection.total_changes - before

    def run_once(self, limit: int = 100) -> MaterializationResult:
        if limit < 1:
            raise ValueError("limit must be at least 1")
        refresh_data_availability(self.database)
        queued = self.ensure_backfill()
        jobs = self.database.fetch_all(
            """SELECT timezone, date FROM dashboard_snapshot_jobs
               ORDER BY created_at, timezone, date LIMIT ?""",
            (limit,),
        )
        completed = failed = 0
        for job in jobs:
            try:
                result = build_day_snapshot(
                    self.database,
                    date.fromisoformat(job["date"]),
                    job["timezone"],
                )
                with self.database.connection() as connection:
                    if result is not None:
                        payload, source_normalized_at = result
                        connection.execute(
                            """INSERT INTO dashboard_day_snapshots(
                                   timezone, date, payload_json,
                                   source_normalized_at, materialized_at
                               ) VALUES (?, ?, ?, ?, ?)
                               ON CONFLICT(timezone, date) DO UPDATE SET
                                   payload_json=excluded.payload_json,
                                   source_normalized_at=excluded.source_normalized_at,
                                   materialized_at=excluded.materialized_at""",
                            (
                                job["timezone"],
                                job["date"],
                                _canonical(payload),
                                source_normalized_at,
                                _now(),
                            ),
                        )
                    connection.execute(
                        "DELETE FROM dashboard_snapshot_jobs WHERE timezone = ? AND date = ?",
                        (job["timezone"], job["date"]),
                    )
                completed += 1
            except Exception as exc:
                with self.database.connection() as connection:
                    connection.execute(
                        """UPDATE dashboard_snapshot_jobs
                           SET attempts=attempts+1, last_attempt_at=?, last_error=?
                           WHERE timezone=? AND date=?""",
                        (
                            _now(),
                            f"{type(exc).__name__}: {exc}"[:2000],
                            job["timezone"],
                            job["date"],
                        ),
                    )
                failed += 1
        return MaterializationResult(queued, completed, failed)
