from __future__ import annotations

import json
from collections import defaultdict
from datetime import UTC, date, datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from .database import Database, decode_json_columns


def _utc(local_date: date, local_time: time, timezone: ZoneInfo) -> str:
    local = datetime.combine(local_date, local_time, timezone)
    return local.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def export_day(database: Database, target_date: date, timezone_name: str = "Asia/Shanghai") -> dict[str, Any]:
    timezone = ZoneInfo(timezone_name)
    day_start = _utc(target_date, time.min, timezone)
    day_end = _utc(target_date + timedelta(days=1), time.min, timezone)
    sleep_start = _utc(target_date - timedelta(days=1), time(18), timezone)
    # One analysis day owns the main sleep that started the previous evening
    # plus naps on the target date. Stopping at 18:00 avoids pulling the next
    # night's sleep into the wrong day.
    sleep_end = _utc(target_date, time(18), timezone)

    quantities = database.fetch_all(
        "SELECT * FROM quantity_samples WHERE start_date >= ? AND start_date < ? ORDER BY start_date, type",
        (day_start, day_end),
    )
    categories = database.fetch_all(
        """SELECT * FROM category_samples
           WHERE start_date >= ? AND start_date < ?
             AND lower(type) NOT LIKE '%sleepanalysis%'
           ORDER BY start_date, type""",
        (day_start, day_end),
    )
    sleep = database.fetch_all(
        """SELECT * FROM category_samples
           WHERE lower(type) LIKE '%sleepanalysis%'
             AND start_date < ? AND end_date > ?
           ORDER BY start_date""",
        (sleep_end, sleep_start),
    )
    workouts = database.fetch_all(
        "SELECT * FROM workouts WHERE start_date >= ? AND start_date < ? ORDER BY start_date",
        (day_start, day_end),
    )
    workout_ids = [workout["uuid"] for workout in workouts]
    routes: list[dict[str, Any]] = []
    if workout_ids:
        placeholders = ", ".join("?" for _ in workout_ids)
        routes = database.fetch_all(
            f"SELECT * FROM workout_routes WHERE workout_uuid IN ({placeholders}) ORDER BY start_date",
            workout_ids,
        )
    activity = database.fetch_all("SELECT * FROM activity_summaries WHERE date = ?", (target_date.isoformat(),))
    normalized_minutes = database.fetch_all(
        """SELECT minute, type, value, min_value, max_value, sample_count,
                  unit, source_name
           FROM normalized_quantity_minutes
           WHERE timezone = ? AND date = ?
           ORDER BY minute, type""",
        (timezone_name, target_date.isoformat()),
    )
    normalized_daily = database.fetch_all(
        "SELECT * FROM normalized_daily_summaries WHERE timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    normalized_sleep = database.fetch_all(
        "SELECT * FROM normalized_sleep_summaries WHERE timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    normalized_workouts = database.fetch_all(
        """SELECT * FROM normalized_workouts
           WHERE timezone = ? AND date = ? ORDER BY start_date""",
        (timezone_name, target_date.isoformat()),
    )
    if normalized_sleep:
        raw_sources = normalized_sleep[0].get("sources_json")
        if isinstance(raw_sources, str):
            try:
                normalized_sleep[0]["sources"] = json.loads(raw_sources)
            except ValueError:
                pass
        normalized_sleep[0].pop("sources_json", None)

    minute_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in quantities:
        start = datetime.fromisoformat(record["start_date"].replace("Z", "+00:00")).astimezone(timezone)
        minute_groups[start.strftime("%Y-%m-%dT%H:%M:00%z")].append(decode_json_columns(record))

    freshness = database.fetch_all(
        """SELECT MAX(received_at) AS last_received_at,
                  MAX(sample_at) AS last_sample_at
           FROM (
             SELECT received_at, end_date AS sample_at FROM quantity_samples
             UNION ALL SELECT received_at, end_date FROM category_samples
             UNION ALL SELECT received_at, end_date FROM workouts
           )"""
    )[0]

    return {
        "schema_version": 2,
        "target_date": target_date.isoformat(),
        "timezone": timezone_name,
        "windows": {
            "day": {"start": day_start, "end": day_end},
            "sleep": {"start": sleep_start, "end": sleep_end},
        },
        "freshness": freshness,
        "quantity_minutes": [
            {"minute": minute, "records": records}
            for minute, records in sorted(minute_groups.items())
        ],
        "category_samples": [decode_json_columns(row) for row in categories],
        "sleep_samples": [decode_json_columns(row) for row in sleep],
        "workouts": [decode_json_columns(row) for row in workouts],
        "workout_routes": [decode_json_columns(row) for row in routes],
        "activity_summary": activity[0] if activity else None,
        "normalized": {
            "daily_summary": normalized_daily[0] if normalized_daily else None,
            "sleep_summary": normalized_sleep[0] if normalized_sleep else None,
            "quantity_minutes": normalized_minutes,
            "workouts": normalized_workouts,
        },
    }
