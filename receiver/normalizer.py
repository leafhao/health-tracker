from __future__ import annotations

import json
import math
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from typing import Any, Iterable
from zoneinfo import ZoneInfo

from .database import Database


STEP_COUNT = "HKQuantityTypeIdentifierStepCount"
DISTANCE_WALK_RUN = "HKQuantityTypeIdentifierDistanceWalkingRunning"
DISTANCE_CYCLING = "HKQuantityTypeIdentifierDistanceCycling"
ACTIVE_ENERGY = "HKQuantityTypeIdentifierActiveEnergyBurned"
BASAL_ENERGY = "HKQuantityTypeIdentifierBasalEnergyBurned"
FLIGHTS = "HKQuantityTypeIdentifierFlightsClimbed"
EXERCISE_TIME = "HKQuantityTypeIdentifierAppleExerciseTime"
STAND_TIME = "HKQuantityTypeIdentifierAppleStandTime"
HEART_RATE = "HKQuantityTypeIdentifierHeartRate"
RESTING_HEART_RATE = "HKQuantityTypeIdentifierRestingHeartRate"
WALKING_HEART_RATE = "HKQuantityTypeIdentifierWalkingHeartRateAverage"
HRV = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
RESPIRATORY_RATE = "HKQuantityTypeIdentifierRespiratoryRate"
OXYGEN_SATURATION = "HKQuantityTypeIdentifierOxygenSaturation"
VO2_MAX = "HKQuantityTypeIdentifierVO2Max"
HEART_RATE_RECOVERY = "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute"
BODY_MASS = "HKQuantityTypeIdentifierBodyMass"
BODY_FAT_PERCENTAGE = "HKQuantityTypeIdentifierBodyFatPercentage"
BODY_MASS_INDEX = "HKQuantityTypeIdentifierBodyMassIndex"
HEIGHT = "HKQuantityTypeIdentifierHeight"
LEAN_BODY_MASS = "HKQuantityTypeIdentifierLeanBodyMass"
SLEEPING_WRIST_TEMPERATURE = "HKQuantityTypeIdentifierAppleSleepingWristTemperature"
RUNNING_POWER = "HKQuantityTypeIdentifierRunningPower"
RUNNING_SPEED = "HKQuantityTypeIdentifierRunningSpeed"
RUNNING_STRIDE = "HKQuantityTypeIdentifierRunningStrideLength"
RUNNING_VERTICAL = "HKQuantityTypeIdentifierRunningVerticalOscillation"
RUNNING_GROUND_CONTACT = "HKQuantityTypeIdentifierRunningGroundContactTime"
SLEEP_TYPE = "HKCategoryTypeIdentifierSleepAnalysis"

CUMULATIVE_TYPES = {
    STEP_COUNT,
    DISTANCE_WALK_RUN,
    DISTANCE_CYCLING,
    ACTIVE_ENERGY,
    BASAL_ENERGY,
    FLIGHTS,
    EXERCISE_TIME,
    STAND_TIME,
}


@dataclass(frozen=True)
class Interval:
    start: datetime
    end: datetime

    @property
    def seconds(self) -> float:
        return max((self.end - self.start).total_seconds(), 0.0)


def _parse(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _timestamp(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _day_bounds(target_date: date, timezone: ZoneInfo) -> tuple[datetime, datetime]:
    start = datetime.combine(target_date, time.min, timezone).astimezone(UTC)
    end = datetime.combine(target_date + timedelta(days=1), time.min, timezone).astimezone(UTC)
    return start, end


def _sleep_bounds(target_date: date, timezone: ZoneInfo) -> tuple[datetime, datetime]:
    start = datetime.combine(target_date - timedelta(days=1), time(18), timezone).astimezone(UTC)
    end = datetime.combine(target_date, time(18), timezone).astimezone(UTC)
    return start, end


def _source_rank(record: dict[str, Any]) -> int:
    joined = " ".join(
        str(record.get(key) or "")
        for key in ("source_name", "source_bundle_id", "device_name")
    ).lower()
    if "watch" in joined or "手表" in joined:
        return 0
    if "iphone" in joined or "手机" in joined:
        return 1
    if "autosleep" in joined:
        return 2
    return 3


def _source_name(record: dict[str, Any]) -> str:
    return str(record.get("source_name") or record.get("source_bundle_id") or "Unknown")


def _sleep_label_kind(label: str) -> str | None:
    """Classify HealthKit sleep semantics without depending on an app name."""
    normalized = label.strip().lower().replace("_", " ")
    if "awake" in normalized:
        return "awake"
    if not normalized.startswith("asleep"):
        if "in bed" in normalized or "inbed" in normalized:
            return "in_bed"
        return None
    if "core" in normalized:
        return "core"
    if "deep" in normalized:
        return "deep"
    if "rem" in normalized:
        return "rem"
    return "unspecified"


def _overlaps(interval: Interval, coverage: Iterable[Interval]) -> bool:
    return any(item.start < interval.end and item.end > interval.start for item in coverage)


def _minute_floor(value: datetime) -> datetime:
    return value.replace(second=0, microsecond=0)


def _split_cumulative(
    record: dict[str, Any], window_start: datetime, window_end: datetime
) -> Iterable[tuple[datetime, float]]:
    sample_start = max(_parse(record["start_date"]), window_start)
    sample_end = min(_parse(record["end_date"]), window_end)
    if sample_end < sample_start:
        return
    value = float(record["value"])
    duration = (sample_end - sample_start).total_seconds()
    if duration <= 0:
        yield _minute_floor(sample_start), value
        return
    cursor = _minute_floor(sample_start)
    while cursor < sample_end:
        minute_end = cursor + timedelta(minutes=1)
        overlap = max((min(sample_end, minute_end) - max(sample_start, cursor)).total_seconds(), 0)
        if overlap:
            yield cursor, value * overlap / duration
        cursor = minute_end


def _merge(intervals: Iterable[Interval], gap_seconds: float = 0) -> list[Interval]:
    ordered = sorted((item for item in intervals if item.end > item.start), key=lambda item: item.start)
    if not ordered:
        return []
    merged = [ordered[0]]
    gap = timedelta(seconds=gap_seconds)
    for item in ordered[1:]:
        previous = merged[-1]
        if item.start <= previous.end + gap:
            merged[-1] = Interval(previous.start, max(previous.end, item.end))
        else:
            merged.append(item)
    return merged


def _subtract(interval: Interval, coverage: Iterable[Interval]) -> list[Interval]:
    pieces = [interval]
    for blocker in _merge(coverage):
        next_pieces: list[Interval] = []
        for piece in pieces:
            if blocker.end <= piece.start or blocker.start >= piece.end:
                next_pieces.append(piece)
                continue
            if blocker.start > piece.start:
                next_pieces.append(Interval(piece.start, min(blocker.start, piece.end)))
            if blocker.end < piece.end:
                next_pieces.append(Interval(max(blocker.end, piece.start), piece.end))
        pieces = next_pieces
    return pieces


def _duration_minutes(intervals: Iterable[Interval]) -> float:
    return sum(item.seconds for item in _merge(intervals)) / 60


def _clip(record: dict[str, Any], start: datetime, end: datetime) -> Interval | None:
    interval = Interval(max(_parse(record["start_date"]), start), min(_parse(record["end_date"]), end))
    return interval if interval.end > interval.start else None


def _mean(values: Iterable[float]) -> float | None:
    finite = [float(value) for value in values if value is not None and math.isfinite(float(value))]
    return statistics.fmean(finite) if finite else None


def _latest(
    database: Database,
    type_id: str,
    before: datetime,
    max_age: timedelta | None = None,
) -> dict[str, Any] | None:
    clauses = ["type = ?", "start_date < ?"]
    parameters: list[Any] = [type_id, _timestamp(before)]
    if max_age is not None:
        clauses.append("start_date >= ?")
        parameters.append(_timestamp(before - max_age))
    rows = database.fetch_all(
        f"""SELECT * FROM quantity_samples
            WHERE {' AND '.join(clauses)}
            ORDER BY start_date DESC LIMIT 1""",
        parameters,
    )
    return rows[0] if rows else None


def _quantity_projection(
    rows: list[dict[str, Any]],
    window_start: datetime,
    window_end: datetime,
    target_date: date,
    timezone_name: str,
    normalized_at: str,
) -> list[dict[str, Any]]:
    cumulative: dict[tuple[datetime, str, int, str], dict[str, Any]] = {}
    discrete: dict[tuple[datetime, str, int, str], dict[str, Any]] = {}

    for row in rows:
        type_id = row["type"]
        rank = _source_rank(row)
        source = _source_name(row)
        if type_id in CUMULATIVE_TYPES:
            for minute, contribution in _split_cumulative(row, window_start, window_end):
                key = (minute, type_id, rank, source)
                bucket = cumulative.setdefault(
                    key,
                    {"values": [], "unit": row.get("unit"), "sample_count": 0},
                )
                bucket["values"].append(contribution)
                bucket["sample_count"] += 1
        else:
            start = _parse(row["start_date"])
            if not window_start <= start < window_end:
                continue
            minute = _minute_floor(start)
            key = (minute, type_id, rank, source)
            bucket = discrete.setdefault(
                key,
                {"values": [], "unit": row.get("unit"), "sample_count": 0},
            )
            bucket["values"].append(float(row["value"]))
            bucket["sample_count"] += 1

    candidates: dict[tuple[datetime, str], list[tuple[int, str, dict[str, Any], bool]]] = defaultdict(list)
    for (minute, type_id, rank, source), bucket in cumulative.items():
        candidates[(minute, type_id)].append((rank, source, bucket, True))
    for (minute, type_id, rank, source), bucket in discrete.items():
        candidates[(minute, type_id)].append((rank, source, bucket, False))

    output: list[dict[str, Any]] = []
    for (minute, type_id), groups in sorted(candidates.items()):
        rank, source, bucket, is_cumulative = min(
            groups,
            key=lambda item: (item[0], -item[2]["sample_count"], item[1]),
        )
        values = bucket["values"]
        value = sum(values) if is_cumulative else statistics.fmean(values)
        output.append(
            {
                "timezone": timezone_name,
                "date": target_date.isoformat(),
                "minute": _timestamp(minute),
                "type": type_id,
                "value": value,
                "min_value": min(values),
                "max_value": max(values),
                "sample_count": bucket["sample_count"],
                "unit": bucket["unit"],
                "source_name": source,
                "source_rank": rank,
                "normalized_at": normalized_at,
            }
        )
    return output


def _sleep_summary(
    rows: list[dict[str, Any]],
    target_date: date,
    timezone_name: str,
    window_start: datetime,
    window_end: datetime,
    normalized_at: str,
) -> dict[str, Any]:
    primary_coverage: list[Interval] = []
    primary_asleep: list[Interval] = []
    stages: dict[str, list[Interval]] = defaultdict(list)
    fallback_asleep: list[Interval] = []
    in_bed: list[Interval] = []
    sources = Counter()

    for row in rows:
        interval = _clip(row, window_start, window_end)
        if interval is None:
            continue
        label = str(row.get("value_label") or "").strip()
        kind = _sleep_label_kind(label)
        source = _source_name(row)
        sources[source] += 1
        if kind in {"core", "deep", "rem"}:
            primary_coverage.append(interval)
            primary_asleep.append(interval)
            stages[kind].append(interval)
        elif kind == "awake":
            primary_coverage.append(interval)
            stages["awake"].append(interval)
        elif kind == "unspecified":
            fallback_asleep.append(interval)
        elif kind == "in_bed":
            in_bed.append(interval)

    # A stage-capable source owns its complete sleep session, including small
    # gaps between samples. Generic "asleep" records that overlap that session
    # are alternate interpretations, not extra sleep. Uncovered generic
    # sessions remain valid fallbacks (for example a daytime nap), and are also
    # the primary data for users without a stage-capable device.
    primary_sessions = _merge(primary_coverage, gap_seconds=90 * 60)
    fallback_uncovered: list[Interval] = []
    for interval in fallback_asleep:
        if not _overlaps(interval, primary_sessions):
            fallback_uncovered.append(interval)
    asleep = _merge([*primary_asleep, *fallback_uncovered])
    sessions = _merge(asleep, gap_seconds=90 * 60)
    main = max(sessions, key=lambda item: item.seconds, default=None)
    main_asleep = 0.0
    if main:
        main_asleep = sum(
            max((min(item.end, main.end) - max(item.start, main.start)).total_seconds(), 0)
            for item in asleep
        ) / 60
    total_asleep = _duration_minutes(asleep)
    nap_minutes = max(total_asleep - main_asleep, 0)
    in_bed_minutes = _duration_minutes(in_bed) if in_bed else None
    main_span = main.seconds / 60 if main else 0
    sleep_continuity = main_asleep / main_span if main_span else None
    if in_bed_minutes and in_bed_minutes >= main_asleep:
        sleep_efficiency = main_asleep / in_bed_minutes
        sleep_efficiency_basis = "in_bed"
    else:
        # Not every device or third-party app writes In Bed samples. Retain a
        # useful fallback, but make its different meaning explicit to clients.
        sleep_efficiency = sleep_continuity
        sleep_efficiency_basis = "main_sleep_window_fallback" if main else None

    return {
        "timezone": timezone_name,
        "date": target_date.isoformat(),
        "window_start": _timestamp(window_start),
        "window_end": _timestamp(window_end),
        "main_sleep_start": _timestamp(main.start) if main else None,
        "main_sleep_end": _timestamp(main.end) if main else None,
        "total_asleep_minutes": total_asleep,
        "main_sleep_minutes": main_asleep,
        "nap_minutes": nap_minutes,
        "core_minutes": _duration_minutes(stages["core"]),
        "deep_minutes": _duration_minutes(stages["deep"]),
        "rem_minutes": _duration_minutes(stages["rem"]),
        "unspecified_minutes": _duration_minutes(fallback_uncovered),
        "awake_minutes": _duration_minutes(stages["awake"]),
        "in_bed_minutes": in_bed_minutes,
        "sleep_efficiency": sleep_efficiency,
        "sleep_continuity": sleep_continuity,
        "sleep_efficiency_basis": sleep_efficiency_basis,
        "session_count": len(sessions),
        "sources_json": json.dumps(dict(sources), ensure_ascii=False, separators=(",", ":")),
        "normalized_at": normalized_at,
    }


def normalized_sleep_segments(
    rows: list[dict[str, Any]], window_start: datetime, window_end: datetime
) -> list[dict[str, Any]]:
    """Return display-ready sleep stages with lower-priority overlaps removed."""
    output: list[dict[str, Any]] = []
    primary_coverage: list[Interval] = []

    primary_rows = [
        row
        for row in rows
        if _sleep_label_kind(str(row.get("value_label") or ""))
        in {"core", "deep", "rem", "awake"}
    ]
    fallback_rows = sorted(
        (
            row
            for row in rows
            if _sleep_label_kind(str(row.get("value_label") or "")) == "unspecified"
        ),
        key=lambda row: (_source_rank(row), _source_name(row), _parse(row["start_date"])),
    )
    for row in primary_rows:
        label = str(row.get("value_label") or "")
        interval = _clip(row, window_start, window_end)
        if interval is None:
            continue
        primary_coverage.append(interval)
        output.append(
            {
                "value_label": label,
                "start_date": _timestamp(interval.start),
                "end_date": _timestamp(interval.end),
                "source_name": _source_name(row),
            }
        )

    primary_sessions = _merge(primary_coverage, gap_seconds=90 * 60)
    fallback_coverage: list[Interval] = []
    for row in fallback_rows:
        interval = _clip(row, window_start, window_end)
        if interval is None or _overlaps(interval, primary_sessions):
            continue
        for piece in _subtract(interval, fallback_coverage):
            fallback_coverage.append(piece)
            output.append(
                {
                    "value_label": "Asleep Unspecified",
                    "start_date": _timestamp(piece.start),
                    "end_date": _timestamp(piece.end),
                    "source_name": _source_name(row),
                }
            )
    return sorted(output, key=lambda row: (row["start_date"], row["end_date"]))


def _elevation_gain(route_rows: list[dict[str, Any]]) -> tuple[float | None, int]:
    altitudes: list[float] = []
    points = 0
    for row in route_rows:
        raw = row.get("locations_json")
        try:
            locations = json.loads(raw) if isinstance(raw, str) else (raw or [])
        except json.JSONDecodeError:
            continue
        points += len(locations)
        for location in locations:
            altitude = location.get("altitude")
            accuracy = location.get("vertical_accuracy")
            if altitude is None:
                continue
            if accuracy is not None and float(accuracy) < 0:
                continue
            altitudes.append(float(altitude))
    if len(altitudes) < 2:
        return None, points
    smoothed: list[float] = []
    for index in range(len(altitudes)):
        window = altitudes[max(index - 2, 0) : min(index + 3, len(altitudes))]
        smoothed.append(statistics.median(window))
    gain = sum(delta for previous, current in zip(smoothed, smoothed[1:]) if 0.5 <= (delta := current - previous) <= 20)
    return gain, points


def _route_preview(route_rows: list[dict[str, Any]], maximum_points: int = 600) -> list[dict[str, float]]:
    points: list[dict[str, float]] = []
    for row in route_rows:
        raw = row.get("locations_json")
        try:
            locations = json.loads(raw) if isinstance(raw, str) else (raw or [])
        except json.JSONDecodeError:
            continue
        for item in locations:
            if not isinstance(item, dict) or "latitude" not in item or "longitude" not in item:
                continue
            points.append(
                {
                    "latitude": float(item["latitude"]),
                    "longitude": float(item["longitude"]),
                }
            )
    if len(points) <= maximum_points:
        return points
    stride = max(len(points) // maximum_points, 1)
    sampled = points[::stride]
    if sampled[-1] != points[-1]:
        sampled.append(points[-1])
    return sampled


def _metric_values(
    database: Database, type_id: str, start: datetime, end: datetime
) -> list[float]:
    rows = database.fetch_all(
        """SELECT value, source_name, source_bundle_id, device_name
           FROM quantity_samples
           WHERE type = ? AND start_date < ? AND end_date > ?""",
        (type_id, _timestamp(end), _timestamp(start)),
    )
    if not rows:
        return []
    best_rank = min(_source_rank(row) for row in rows)
    return [float(row["value"]) for row in rows if _source_rank(row) == best_rank]


def _heart_rate_zone_context(database: Database, before: datetime) -> dict[str, float] | None:
    """Build transparent personal HR-reserve zones from available history.

    HealthKit does not expose the Apple Watch workout-zone configuration to a
    third-party reader. We therefore use the user's observed 90-day maximum
    and 28-day resting-HR median, and omit zones when either input is absent.
    """
    heart_rates = [
        value
        for value in _metric_values(database, HEART_RATE, before - timedelta(days=90), before)
        if 30 <= value <= 240
    ]
    resting = [
        value
        for value in _metric_values(
            database, RESTING_HEART_RATE, before - timedelta(days=28), before
        )
        if 30 <= value <= 150
    ]
    if not heart_rates or not resting:
        return None
    resting_bpm = statistics.median(resting)
    maximum_bpm = max(heart_rates)
    if maximum_bpm <= resting_bpm + 30:
        return None
    reserve = maximum_bpm - resting_bpm
    return {
        "resting_bpm": resting_bpm,
        "maximum_bpm": maximum_bpm,
        "zone_2_bpm": resting_bpm + reserve * 0.60,
        "zone_3_bpm": resting_bpm + reserve * 0.70,
        "zone_4_bpm": resting_bpm + reserve * 0.80,
        "zone_5_bpm": resting_bpm + reserve * 0.90,
    }


def _workout_heart_rate_zones(
    database: Database,
    target_date: date,
    timezone_name: str,
    start: datetime,
    end: datetime,
    context: dict[str, float] | None,
) -> tuple[dict[str, Any], str | None]:
    if context is None:
        return {}, None
    rows = database.fetch_all(
        """SELECT minute, value FROM normalized_quantity_minutes
           WHERE timezone = ? AND date = ? AND type = ?
             AND minute >= ? AND minute < ? ORDER BY minute""",
        (
            timezone_name,
            target_date.isoformat(),
            HEART_RATE,
            _timestamp(_minute_floor(start)),
            _timestamp(end),
        ),
    )
    if not rows:
        return {}, "personal-heart-rate-reserve-observed-v1"
    thresholds = [
        context["zone_2_bpm"],
        context["zone_3_bpm"],
        context["zone_4_bpm"],
        context["zone_5_bpm"],
    ]
    minutes = {f"zone_{index}": 0.0 for index in range(1, 6)}
    covered = 0.0
    for row in rows:
        minute_start = _parse(row["minute"])
        overlap = max(
            (
                min(end, minute_start + timedelta(minutes=1))
                - max(start, minute_start)
            ).total_seconds(),
            0,
        ) / 60
        if overlap <= 0:
            continue
        bpm = float(row["value"])
        zone = 1 + sum(bpm >= threshold for threshold in thresholds)
        minutes[f"zone_{zone}"] += overlap
        covered += overlap
    return (
        {
            "minutes": minutes,
            "covered_minutes": covered,
            "reference_resting_bpm": context["resting_bpm"],
            "reference_maximum_bpm": context["maximum_bpm"],
            "lower_bounds_bpm": {
                "zone_2": context["zone_2_bpm"],
                "zone_3": context["zone_3_bpm"],
                "zone_4": context["zone_4_bpm"],
                "zone_5": context["zone_5_bpm"],
            },
        },
        "personal-heart-rate-reserve-observed-v1",
    )


def _cumulative_window(
    database: Database, type_id: str, start: datetime, end: datetime
) -> float | None:
    rows = database.fetch_all(
        """SELECT * FROM quantity_samples
           WHERE type = ? AND start_date < ? AND end_date > ?""",
        (type_id, _timestamp(end), _timestamp(start)),
    )
    projection = _quantity_projection(rows, start, end, start.date(), "UTC", _timestamp(datetime.now(UTC)))
    values = [row["value"] for row in projection if row["type"] == type_id]
    return sum(values) if values else None


def _workout_summaries(
    database: Database,
    workouts: list[dict[str, Any]],
    target_date: date,
    timezone_name: str,
    normalized_at: str,
) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    _, day_end = _day_bounds(target_date, ZoneInfo(timezone_name))
    zone_context = _heart_rate_zone_context(database, day_end)
    for workout in workouts:
        start = _parse(workout["start_date"])
        end = _parse(workout["end_date"])
        duration = float(workout["duration_seconds"])
        distance = workout.get("total_distance_meters")
        activity_name = str(workout["activity_type"]).lower()
        pace_distance = distance if any(
            name in activity_name for name in ("running", "walking", "hiking")
        ) else None
        route_rows = database.fetch_all(
            "SELECT * FROM workout_routes WHERE workout_uuid = ? ORDER BY start_date",
            (workout["uuid"],),
        )
        elevation_gain, route_points = _elevation_gain(route_rows)
        heart_rates = _metric_values(database, HEART_RATE, start, end)
        heart_rate_zones, heart_rate_zone_method = _workout_heart_rate_zones(
            database,
            target_date,
            timezone_name,
            start,
            end,
            zone_context,
        )
        steps = _cumulative_window(database, STEP_COUNT, start, end)
        cadence = None
        if "running" in activity_name and steps and duration > 0:
            cadence = steps / (duration / 60)
        output.append(
            {
                "uuid": workout["uuid"],
                "timezone": timezone_name,
                "date": target_date.isoformat(),
                "activity_type": workout["activity_type"],
                "start_date": workout["start_date"],
                "end_date": workout["end_date"],
                "duration_seconds": duration,
                "energy_kcal": workout.get("total_energy_burned_kcal"),
                "distance_meters": distance,
                "pace_seconds_per_km": duration / (float(pace_distance) / 1000)
                if pace_distance
                else None,
                "flights_climbed": workout.get("total_flights_climbed")
                if workout.get("total_flights_climbed") is not None
                else _cumulative_window(database, FLIGHTS, start, end),
                "elevation_gain_meters": elevation_gain,
                "route_points": route_points,
                "heart_rate_samples": len(heart_rates),
                "heart_rate_avg_bpm": _mean(heart_rates),
                "heart_rate_min_bpm": min(heart_rates) if heart_rates else None,
                "heart_rate_max_bpm": max(heart_rates) if heart_rates else None,
                "cadence_steps_per_minute": cadence,
                "running_power_watts": _mean(_metric_values(database, RUNNING_POWER, start, end)),
                "running_speed_meters_per_second": _mean(_metric_values(database, RUNNING_SPEED, start, end)),
                "running_stride_length_meters": _mean(_metric_values(database, RUNNING_STRIDE, start, end)),
                "running_vertical_oscillation_cm": _mean(_metric_values(database, RUNNING_VERTICAL, start, end)),
                "running_ground_contact_time_ms": _mean(_metric_values(database, RUNNING_GROUND_CONTACT, start, end)),
                "source_name": workout.get("source_name"),
                "heart_rate_zones_json": json.dumps(
                    heart_rate_zones, ensure_ascii=False, separators=(",", ":")
                ),
                "heart_rate_zone_method": heart_rate_zone_method,
                "route_preview_json": json.dumps(
                    _route_preview(route_rows), ensure_ascii=False, separators=(",", ":")
                ),
                "normalized_at": normalized_at,
            }
        )
    return output


def _sleep_vitals(database: Database, sleep_summary: dict[str, Any]) -> dict[str, float | None]:
    start_value = sleep_summary.get("main_sleep_start")
    end_value = sleep_summary.get("main_sleep_end")
    empty = {
        "sleeping_heart_rate_avg_bpm": None,
        "sleeping_heart_rate_min_bpm": None,
        "sleeping_heart_rate_max_bpm": None,
        "sleeping_hrv_sdnn_ms": None,
        "sleeping_respiratory_rate": None,
        "sleeping_oxygen_avg_percent": None,
        "sleeping_oxygen_min_percent": None,
        "sleeping_wrist_temperature_c": None,
    }
    if not start_value or not end_value:
        return empty
    start, end = _parse(start_value), _parse(end_value)
    heart_rates = _metric_values(database, HEART_RATE, start, end)
    hrv = _metric_values(database, HRV, start, end)
    respiratory = _metric_values(database, RESPIRATORY_RATE, start, end)
    oxygen = _metric_values(database, OXYGEN_SATURATION, start, end)
    oxygen = [value * 100 if value <= 1.5 else value for value in oxygen]
    temperatures = _metric_values(database, SLEEPING_WRIST_TEMPERATURE, start, end)
    return {
        "sleeping_heart_rate_avg_bpm": _mean(heart_rates),
        "sleeping_heart_rate_min_bpm": min(heart_rates) if heart_rates else None,
        "sleeping_heart_rate_max_bpm": max(heart_rates) if heart_rates else None,
        "sleeping_hrv_sdnn_ms": _mean(hrv),
        "sleeping_respiratory_rate": _mean(respiratory),
        "sleeping_oxygen_avg_percent": _mean(oxygen),
        "sleeping_oxygen_min_percent": min(oxygen) if oxygen else None,
        "sleeping_wrist_temperature_c": _mean(temperatures),
    }


def _training_summary(
    workouts: list[dict[str, Any]],
    target_date: date,
    timezone_name: str,
    normalized_at: str,
) -> dict[str, Any]:
    zone_minutes = {f"zone_{index}": 0.0 for index in range(1, 6)}
    covered = 0.0
    for workout in workouts:
        try:
            zones = json.loads(workout.get("heart_rate_zones_json") or "{}")
        except (TypeError, json.JSONDecodeError):
            zones = {}
        covered += float(zones.get("covered_minutes") or 0)
        values = zones.get("minutes") or {}
        for key in zone_minutes:
            zone_minutes[key] += float(values.get(key) or 0)
    load_score = sum(zone_minutes[f"zone_{index}"] * index for index in range(1, 6))
    return {
        "timezone": timezone_name,
        "date": target_date.isoformat(),
        "workout_count": len(workouts),
        "workout_minutes": sum(float(row["duration_seconds"]) for row in workouts) / 60,
        "energy_kcal": sum(float(row.get("energy_kcal") or 0) for row in workouts),
        "heart_rate_covered_minutes": covered,
        "zone_1_minutes": zone_minutes["zone_1"],
        "zone_2_minutes": zone_minutes["zone_2"],
        "zone_3_minutes": zone_minutes["zone_3"],
        "zone_4_minutes": zone_minutes["zone_4"],
        "zone_5_minutes": zone_minutes["zone_5"],
        "high_intensity_minutes": zone_minutes["zone_4"] + zone_minutes["zone_5"],
        "load_score": load_score,
        "normalized_at": normalized_at,
    }


def _daily_summary(
    database: Database,
    target_date: date,
    timezone_name: str,
    day_end: datetime,
    normalized_at: str,
) -> dict[str, Any]:
    minute_rows = database.fetch_all(
        "SELECT type, value FROM normalized_quantity_minutes WHERE timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    by_type: dict[str, list[float]] = defaultdict(list)
    for row in minute_rows:
        by_type[row["type"]].append(float(row["value"]))

    activity_rows = database.fetch_all(
        "SELECT * FROM activity_summaries WHERE date = ?", (target_date.isoformat(),)
    )
    activity = activity_rows[0] if activity_rows else {}

    def total(type_id: str) -> float | None:
        return sum(by_type[type_id]) if by_type[type_id] else None

    def average(type_id: str) -> float | None:
        return _mean(by_type[type_id])

    vo2 = _latest(database, VO2_MAX, day_end)
    recovery = _latest(database, HEART_RATE_RECOVERY, day_end)
    body_measurement_max_age = timedelta(days=30)
    body_mass = _latest(database, BODY_MASS, day_end, body_measurement_max_age)
    body_fat = _latest(database, BODY_FAT_PERCENTAGE, day_end, body_measurement_max_age)
    body_mass_index = _latest(database, BODY_MASS_INDEX, day_end, body_measurement_max_age)
    height = _latest(database, HEIGHT, day_end)
    lean_body_mass = _latest(database, LEAN_BODY_MASS, day_end, body_measurement_max_age)
    oxygen = average(OXYGEN_SATURATION)
    if oxygen is not None and oxygen <= 1.5:
        oxygen *= 100

    body_mass_kg = float(body_mass["value"]) if body_mass else None
    body_fat_percent = float(body_fat["value"]) if body_fat else None
    if body_fat_percent is not None and body_fat_percent <= 1.5:
        body_fat_percent *= 100
    height_m = float(height["value"]) if height else None

    if body_mass_index:
        bmi = float(body_mass_index["value"])
        bmi_at = body_mass_index["start_date"]
        bmi_source = "healthkit"
    elif body_mass_kg is not None and height_m is not None and height_m > 0:
        bmi = body_mass_kg / (height_m * height_m)
        bmi_at = max(body_mass["start_date"], height["start_date"])
        bmi_source = "calculated"
    else:
        bmi = bmi_at = bmi_source = None

    if lean_body_mass:
        lean_mass_kg = float(lean_body_mass["value"])
        lean_mass_at = lean_body_mass["start_date"]
        lean_mass_source = "healthkit"
    elif body_mass_kg is not None and body_fat_percent is not None:
        lean_mass_kg = body_mass_kg * (1 - body_fat_percent / 100)
        lean_mass_at = max(body_mass["start_date"], body_fat["start_date"])
        lean_mass_source = "calculated"
    else:
        lean_mass_kg = lean_mass_at = lean_mass_source = None

    return {
        "timezone": timezone_name,
        "date": target_date.isoformat(),
        "steps": total(STEP_COUNT),
        "walking_running_distance_m": total(DISTANCE_WALK_RUN),
        "cycling_distance_m": total(DISTANCE_CYCLING),
        "active_energy_kcal": activity.get("active_energy_burned") or total(ACTIVE_ENERGY),
        "basal_energy_kcal": total(BASAL_ENERGY),
        "flights_climbed": total(FLIGHTS),
        "exercise_minutes": activity.get("exercise_time_minutes") or total(EXERCISE_TIME),
        "stand_hours": activity.get("stand_hours"),
        "resting_heart_rate_bpm": average(RESTING_HEART_RATE),
        "walking_heart_rate_bpm": average(WALKING_HEART_RATE),
        "hrv_sdnn_ms": average(HRV),
        "respiratory_rate": average(RESPIRATORY_RATE),
        "oxygen_saturation_percent": oxygen,
        "vo2_max": float(vo2["value"]) if vo2 else None,
        "vo2_max_at": vo2["start_date"] if vo2 else None,
        "heart_rate_recovery_bpm": float(recovery["value"]) if recovery else None,
        "heart_rate_recovery_at": recovery["start_date"] if recovery else None,
        "body_mass_kg": body_mass_kg,
        "body_mass_at": body_mass["start_date"] if body_mass else None,
        "body_fat_percent": body_fat_percent,
        "body_fat_at": body_fat["start_date"] if body_fat else None,
        "body_mass_index": bmi,
        "body_mass_index_at": bmi_at,
        "body_mass_index_source": bmi_source,
        "lean_body_mass_kg": lean_mass_kg,
        "lean_body_mass_at": lean_mass_at,
        "lean_body_mass_source": lean_mass_source,
        "normalized_at": normalized_at,
    }


def _replace_rows(database: Database, table: str, rows: list[dict[str, Any]], where: str, params: tuple[Any, ...]) -> None:
    with database.connection() as connection:
        connection.execute(f"DELETE FROM {table} WHERE {where}", params)
        if not rows:
            return
        columns = list(rows[0])
        connection.executemany(
            f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join('?' for _ in columns)})",
            [[row[column] for column in columns] for row in rows],
        )


def normalize_day(
    database: Database, target_date: date, timezone_name: str = "Asia/Shanghai"
) -> dict[str, Any]:
    timezone = ZoneInfo(timezone_name)
    day_start, day_end = _day_bounds(target_date, timezone)
    sleep_start, sleep_end = _sleep_bounds(target_date, timezone)
    normalized_at = _timestamp(datetime.now(UTC))

    quantities = database.fetch_all(
        """SELECT * FROM quantity_samples
           WHERE start_date < ? AND end_date >= ?
           ORDER BY start_date, type""",
        (_timestamp(day_end), _timestamp(day_start)),
    )
    sleep_rows = database.fetch_all(
        """SELECT * FROM category_samples
           WHERE type = ?
             AND start_date < ? AND end_date > ?
           ORDER BY start_date""",
        (SLEEP_TYPE, _timestamp(sleep_end), _timestamp(sleep_start)),
    )
    workouts = database.fetch_all(
        "SELECT * FROM workouts WHERE start_date >= ? AND start_date < ? ORDER BY start_date",
        (_timestamp(day_start), _timestamp(day_end)),
    )

    minute_rows = _quantity_projection(
        quantities, day_start, day_end, target_date, timezone_name, normalized_at
    )
    _replace_rows(
        database,
        "normalized_quantity_minutes",
        minute_rows,
        "timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    sleep_summary = _sleep_summary(
        sleep_rows, target_date, timezone_name, sleep_start, sleep_end, normalized_at
    )
    sleep_summary.update(_sleep_vitals(database, sleep_summary))
    sleep_summary["segments_json"] = json.dumps(
        normalized_sleep_segments(sleep_rows, sleep_start, sleep_end),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    daily_summary = _daily_summary(database, target_date, timezone_name, day_end, normalized_at)
    workout_summaries = _workout_summaries(
        database, workouts, target_date, timezone_name, normalized_at
    )
    training_summary = _training_summary(
        workout_summaries, target_date, timezone_name, normalized_at
    )

    _replace_rows(
        database,
        "normalized_sleep_summaries",
        [sleep_summary],
        "timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    _replace_rows(
        database,
        "normalized_daily_summaries",
        [daily_summary],
        "timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    _replace_rows(
        database,
        "normalized_workouts",
        workout_summaries,
        "timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    _replace_rows(
        database,
        "normalized_training_summaries",
        [training_summary],
        "timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    run = {
        "timezone": timezone_name,
        "date": target_date.isoformat(),
        "raw_quantity_count": len(quantities),
        "raw_sleep_count": len(sleep_rows),
        "raw_workout_count": len(workouts),
        "normalized_at": normalized_at,
    }
    _replace_rows(
        database,
        "normalization_runs",
        [run],
        "timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    return {
        "date": target_date.isoformat(),
        "timezone": timezone_name,
        "quantity_minutes": len(minute_rows),
        "sleep": sleep_summary,
        "daily": daily_summary,
        "workouts": len(workout_summaries),
        "training": training_summary,
        "normalized_at": normalized_at,
    }


def normalize_range(
    database: Database,
    start_date: date,
    end_date: date,
    timezone_name: str = "Asia/Shanghai",
) -> list[dict[str, Any]]:
    if end_date < start_date:
        raise ValueError("end_date must be on or after start_date")
    results = []
    cursor = start_date
    while cursor <= end_date:
        results.append(normalize_day(database, cursor, timezone_name))
        cursor += timedelta(days=1)
    return results
