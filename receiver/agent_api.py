from __future__ import annotations

import ipaddress
import json
import statistics
from datetime import UTC, date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException, Request, status

from .dashboard import _dashboard_insights, _data_availability, _decode_sources
from .database import Database


AGENT_SCHEMA_VERSION = 1
MAX_SERIES_DAYS = 365


def _metric(
    group: str,
    unit: str | None,
    acquisition: str,
    calculation: str,
    meaning: str,
    caveat: str | None = None,
) -> dict[str, Any]:
    return {
        "group": group,
        "unit": unit,
        "acquisition": acquisition,
        "calculation": calculation,
        "meaning": meaning,
        "caveat": caveat,
    }


# This dictionary is part of the public Agent contract. Keep definitions here,
# beside the values they explain, so a local Agent never has to infer units or
# reverse-engineer calculations from the dashboard.
METRIC_CATALOG: dict[str, dict[str, Any]] = {
    "steps": _metric("activity", "count", "HealthKit StepCount", "按分钟选择优先来源后求和", "日常活动量"),
    "walking_running_distance_m": _metric("activity", "m", "HealthKit DistanceWalkingRunning", "按分钟去重后求和", "步行和跑步距离"),
    "cycling_distance_m": _metric("activity", "m", "HealthKit DistanceCycling", "按分钟去重后求和", "骑行距离"),
    "active_energy_kcal": _metric("activity", "kcal", "优先 HealthKit Activity Summary，否则 ActiveEnergyBurned", "当日求和", "主动活动消耗"),
    "basal_energy_kcal": _metric("activity", "kcal", "HealthKit BasalEnergyBurned", "当日求和", "基础代谢消耗估计"),
    "flights_climbed": _metric("activity", "floors", "HealthKit FlightsClimbed", "按分钟去重后求和", "垂直活动量"),
    "exercise_minutes": _metric("activity", "min", "优先 HealthKit Activity Summary，否则 AppleExerciseTime", "当日求和", "Apple 定义的锻炼时间"),
    "stand_hours": _metric("activity", "h", "HealthKit Activity Summary", "读取当日站立小时", "久坐情况参考"),
    "resting_heart_rate_bpm": _metric("cardio_recovery", "bpm", "HealthKit RestingHeartRate", "当天优先来源样本平均值", "与个人基线比较恢复和压力"),
    "walking_heart_rate_bpm": _metric("cardio_recovery", "bpm", "HealthKit WalkingHeartRateAverage", "当天优先来源样本平均值", "相似日常活动下的心脏负担"),
    "hrv_sdnn_ms": _metric("cardio_recovery", "ms", "HealthKit HeartRateVariabilitySDNN", "当天优先来源样本平均值", "自主神经恢复趋势", "主要用于个人纵向比较，不是独立诊断"),
    "respiratory_rate": _metric("cardio_recovery", "breaths/min", "HealthKit RespiratoryRate", "当天优先来源样本平均值", "呼吸频率趋势"),
    "oxygen_saturation_percent": _metric("cardio_recovery", "%", "HealthKit OxygenSaturation", "当天优先来源样本平均值并统一为百分数", "血氧趋势", "稀疏样本不能替代医疗级持续监测"),
    "vo2_max": _metric("cardio_recovery", "mL/kg/min", "HealthKit VO2Max", "取截止分析日最近一次测量，并同时返回 vo2_max_at", "有氧能力趋势", "可能不是分析日当天测量"),
    "heart_rate_recovery_bpm": _metric("cardio_recovery", "bpm", "HealthKit HeartRateRecoveryOneMinute", "取截止分析日最近一次测量，并同时返回 heart_rate_recovery_at", "运动后一分钟恢复参考", "可能不是分析日当天测量"),
    "body_mass_kg": _metric("body", "kg", "HealthKit BodyMass", "取截止分析日最近一次测量，并同时返回 body_mass_at", "体重趋势背景", "可能不是分析日当天测量"),
    "main_sleep_start": _metric("sleep", None, "HealthKit SleepAnalysis", "分析窗口内最长合并睡眠时段的开始", "入睡时间与作息规律"),
    "main_sleep_end": _metric("sleep", None, "HealthKit SleepAnalysis", "分析窗口内最长合并睡眠时段的结束", "起床时间与作息规律"),
    "total_asleep_minutes": _metric("sleep", "min", "HealthKit SleepAnalysis", "睡眠窗口内去重后的全部睡眠", "主睡眠与午睡总量"),
    "main_sleep_minutes": _metric("sleep", "min", "HealthKit SleepAnalysis", "最长睡眠时段内实际睡着分钟", "夜间核心睡眠量"),
    "nap_minutes": _metric("sleep", "min", "HealthKit SleepAnalysis", "总睡眠减主睡眠", "白天补眠量"),
    "core_minutes": _metric("sleep", "min", "Apple Watch SleepAnalysis", "去重后的 Core 阶段时长", "核心睡眠结构"),
    "deep_minutes": _metric("sleep", "min", "Apple Watch SleepAnalysis", "去重后的 Deep 阶段时长", "深睡结构"),
    "rem_minutes": _metric("sleep", "min", "Apple Watch SleepAnalysis", "去重后的 REM 阶段时长", "快速眼动睡眠结构"),
    "awake_minutes": _metric("sleep", "min", "Apple Watch SleepAnalysis", "睡眠窗口内 Awake 片段时长", "夜间清醒和中断"),
    "sleep_efficiency": _metric("sleep", "ratio", "规范化睡眠摘要", "优先主睡眠分钟÷卧床分钟；无卧床样本时退化为连续率", "卧床时间利用程度", "必须同时读取 sleep_efficiency_basis"),
    "sleep_continuity": _metric("sleep", "ratio", "规范化睡眠摘要", "主睡眠实际睡着分钟÷主睡眠起止跨度", "睡眠碎片化程度"),
    "session_count": _metric("sleep", "count", "规范化睡眠摘要", "相隔不超过 90 分钟的睡眠片段合并为一个时段", "主睡眠与午睡时段数量"),
    "sleeping_heart_rate_avg_bpm": _metric("sleep_vitals", "bpm", "主睡眠时间内 HealthKit HeartRate", "优先来源样本平均值", "夜间心率负担"),
    "sleeping_heart_rate_min_bpm": _metric("sleep_vitals", "bpm", "主睡眠时间内 HealthKit HeartRate", "优先来源样本最低值", "夜间最低心率"),
    "sleeping_heart_rate_max_bpm": _metric("sleep_vitals", "bpm", "主睡眠时间内 HealthKit HeartRate", "优先来源样本最高值", "夜间最高心率和异常波动线索", "单个峰值需结合样本与睡眠阶段解释"),
    "sleeping_hrv_sdnn_ms": _metric("sleep_vitals", "ms", "主睡眠时间内 HealthKit HRV SDNN", "优先来源样本平均值", "睡眠期间恢复趋势"),
    "sleeping_respiratory_rate": _metric("sleep_vitals", "breaths/min", "主睡眠时间内 HealthKit RespiratoryRate", "优先来源样本平均值", "睡眠呼吸趋势"),
    "sleeping_oxygen_avg_percent": _metric("sleep_vitals", "%", "主睡眠时间内 HealthKit OxygenSaturation", "优先来源样本平均值", "睡眠血氧趋势", "稀疏样本不能表示整夜持续血氧"),
    "sleeping_oxygen_min_percent": _metric("sleep_vitals", "%", "主睡眠时间内 HealthKit OxygenSaturation", "优先来源样本最低值", "观察偶发低值", "最低单样本不等于持续低血氧"),
    "sleeping_wrist_temperature_c": _metric("sleep_vitals", "°C", "HealthKit AppleSleepingWristTemperature", "主睡眠窗口内优先来源样本平均值", "腕温相对个人基线变化"),
    "workout_count": _metric("training", "count", "HealthKit Workout", "分析日训练记录数量", "训练频次"),
    "workout_minutes": _metric("training", "min", "HealthKit Workout", "当日所有训练时长求和", "训练总量"),
    "training_energy_kcal": _metric("training", "kcal", "HealthKit Workout", "当日训练能量求和", "训练能量消耗"),
    "heart_rate_covered_minutes": _metric("training", "min", "训练窗口内分钟心率", "存在有效心率的训练分钟", "训练负荷的数据覆盖程度"),
    "zone_1_minutes": _metric("training", "min", "训练窗口内心率", "个人心率储备 Z1 分钟", "低强度时间"),
    "zone_2_minutes": _metric("training", "min", "训练窗口内心率", "个人心率储备 Z2 分钟", "低至中等强度时间"),
    "zone_3_minutes": _metric("training", "min", "训练窗口内心率", "个人心率储备 Z3 分钟", "中等强度时间"),
    "zone_4_minutes": _metric("training", "min", "训练窗口内心率", "个人心率储备 Z4 分钟", "高强度时间"),
    "zone_5_minutes": _metric("training", "min", "训练窗口内心率", "个人心率储备 Z5 分钟", "最高强度时间"),
    "high_intensity_minutes": _metric("training", "min", "规范化训练心率区间", "Z4+Z5 分钟", "高强度训练量"),
    "load_score": _metric("training", "points", "规范化训练心率区间", "Z1×1+Z2×2+Z3×3+Z4×4+Z5×5", "个人训练负荷趋势", "无心率覆盖的训练只计时长，不计负荷；不是医学处方或 TRIMP"),
}


WORKOUT_FIELD_CATALOG: dict[str, dict[str, Any]] = {
    "activity_type": _metric("workout", None, "HealthKit Workout", "读取训练类型", "区分跑步、步行、骑行等训练"),
    "start_date": _metric("workout", None, "HealthKit Workout", "训练开始时间", "训练发生时间"),
    "end_date": _metric("workout", None, "HealthKit Workout", "训练结束时间", "训练结束时间"),
    "duration_seconds": _metric("workout", "s", "HealthKit Workout", "读取训练时长", "单次训练规模"),
    "energy_kcal": _metric("workout", "kcal", "HealthKit Workout", "读取训练活动能量", "单次训练能量消耗"),
    "distance_meters": _metric("workout", "m", "HealthKit Workout", "读取训练距离", "单次训练距离"),
    "pace_seconds_per_km": _metric("workout", "s/km", "训练时长与距离", "仅对跑步、步行和徒步计算时长÷公里", "单次训练配速"),
    "flights_climbed": _metric("workout", "floors", "Workout 或训练窗口内 FlightsClimbed", "优先 Workout 自带值", "楼梯训练量"),
    "elevation_gain_meters": _metric("workout", "m", "HealthKit WorkoutRoute", "累计路线中合理的正向海拔变化", "户外训练爬升"),
    "route_points": _metric("workout", "count", "HealthKit WorkoutRoute", "路线点数量；坐标默认不返回", "判断是否有可用 GPS 路线"),
    "heart_rate_samples": _metric("workout", "count", "训练窗口内 HealthKit HeartRate", "优先来源心率样本数量", "单次训练心率覆盖质量"),
    "heart_rate_avg_bpm": _metric("workout", "bpm", "训练窗口内 HealthKit HeartRate", "优先来源平均值", "单次训练平均强度"),
    "heart_rate_min_bpm": _metric("workout", "bpm", "训练窗口内 HealthKit HeartRate", "优先来源最低值", "单次训练心率范围"),
    "heart_rate_max_bpm": _metric("workout", "bpm", "训练窗口内 HealthKit HeartRate", "优先来源最高值", "单次训练峰值强度"),
    "heart_rate_zones": _metric("workout", "min", "训练窗口内分钟心率", "用近 90 天实测最高心率和近 28 天静息心率中位数计算心率储备五区", "单次训练强度分布", "不是 Apple Watch 私有区间设置"),
    "cadence_steps_per_minute": _metric("workout", "steps/min", "训练窗口内步数", "当前跑步训练使用步数÷分钟估算", "跑步节奏", "估算值；存在专项步频时后续可优先采用"),
    "running_power_watts": _metric("workout", "W", "HealthKit RunningPower", "训练窗口内优先来源样本平均值", "跑步输出"),
    "running_speed_meters_per_second": _metric("workout", "m/s", "HealthKit RunningSpeed", "训练窗口内优先来源样本平均值", "跑步速度"),
    "running_stride_length_meters": _metric("workout", "m", "HealthKit RunningStrideLength", "训练窗口内优先来源样本平均值", "跑步步幅"),
    "running_vertical_oscillation_cm": _metric("workout", "cm", "HealthKit RunningVerticalOscillation", "训练窗口内优先来源样本平均值", "跑姿垂直振幅"),
    "running_ground_contact_time_ms": _metric("workout", "ms", "HealthKit RunningGroundContactTime", "训练窗口内优先来源样本平均值", "跑步触地时间"),
    "source_name": _metric("workout", None, "HealthKit SourceRevision", "保留写入来源名称", "判断数据来自 Watch、手机或第三方 App"),
}


SERIES_METRICS: dict[str, tuple[str, str, str | None]] = {
    key: ("normalized_daily_summaries", key, None)
    for key in (
        "steps", "walking_running_distance_m", "cycling_distance_m", "active_energy_kcal",
        "basal_energy_kcal", "flights_climbed", "exercise_minutes", "stand_hours",
        "resting_heart_rate_bpm", "walking_heart_rate_bpm", "hrv_sdnn_ms",
        "respiratory_rate", "oxygen_saturation_percent",
    )
}
SERIES_METRICS.update({
    "vo2_max": ("normalized_daily_summaries", "vo2_max", "vo2_max_at"),
    "heart_rate_recovery_bpm": ("normalized_daily_summaries", "heart_rate_recovery_bpm", "heart_rate_recovery_at"),
    "body_mass_kg": ("normalized_daily_summaries", "body_mass_kg", "body_mass_at"),
})
SERIES_METRICS.update({
    key: ("normalized_sleep_summaries", key, None)
    for key in (
        "total_asleep_minutes", "main_sleep_minutes", "nap_minutes", "core_minutes",
        "deep_minutes", "rem_minutes", "awake_minutes", "sleep_efficiency",
        "sleep_continuity", "session_count", "sleeping_heart_rate_avg_bpm",
        "sleeping_heart_rate_min_bpm", "sleeping_hrv_sdnn_ms",
        "sleeping_respiratory_rate", "sleeping_oxygen_avg_percent",
        "sleeping_oxygen_min_percent", "sleeping_wrist_temperature_c",
    )
})
SERIES_METRICS.update({
    key: ("normalized_training_summaries", column, None)
    for key, column in {
        "workout_count": "workout_count",
        "workout_minutes": "workout_minutes",
        "training_energy_kcal": "energy_kcal",
        "heart_rate_covered_minutes": "heart_rate_covered_minutes",
        "zone_1_minutes": "zone_1_minutes",
        "zone_2_minutes": "zone_2_minutes",
        "zone_3_minutes": "zone_3_minutes",
        "zone_4_minutes": "zone_4_minutes",
        "zone_5_minutes": "zone_5_minutes",
        "high_intensity_minutes": "high_intensity_minutes",
        "load_score": "load_score",
    }.items()
})


TREND_METRICS = (
    "main_sleep_minutes", "nap_minutes", "sleep_efficiency",
    "resting_heart_rate_bpm", "hrv_sdnn_ms", "sleeping_heart_rate_avg_bpm",
    "sleeping_respiratory_rate", "sleeping_oxygen_avg_percent",
    "steps", "active_energy_kcal", "workout_minutes", "load_score",
    "high_intensity_minutes", "vo2_max",
)


def _loopback(value: str | None) -> bool:
    if value in {"localhost", "testclient", "testserver"}:
        return True
    if not value:
        return False
    try:
        return ipaddress.ip_address(value.split("%", 1)[0]).is_loopback
    except ValueError:
        return False


def _require_local_agent(request: Request) -> None:
    client_host = request.client.host if request.client else None
    if not (_loopback(client_host) and _loopback(request.url.hostname)):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Agent API 仅允许 Receiver 本机通过 localhost 访问",
        )


def _validate_timezone(timezone_name: str) -> ZoneInfo:
    try:
        return ZoneInfo(timezone_name)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="invalid timezone") from exc


def _one(database: Database, table: str, target_date: date, timezone_name: str) -> dict[str, Any] | None:
    rows = database.fetch_all(
        f"SELECT * FROM {table} WHERE timezone = ? AND date = ?",
        (timezone_name, target_date.isoformat()),
    )
    return rows[0] if rows else None


def _workouts(database: Database, target_date: date, timezone_name: str) -> list[dict[str, Any]]:
    rows = database.fetch_all(
        """SELECT * FROM normalized_workouts
           WHERE timezone = ? AND date = ? ORDER BY start_date""",
        (timezone_name, target_date.isoformat()),
    )
    output: list[dict[str, Any]] = []
    for row in rows:
        item = dict(row)
        item.pop("route_preview_json", None)
        raw_zones = item.pop("heart_rate_zones_json", "{}")
        try:
            item["heart_rate_zones"] = json.loads(raw_zones or "{}")
        except (TypeError, json.JSONDecodeError):
            item["heart_rate_zones"] = {}
        # Coordinates and raw metadata are deliberately excluded from the
        # default local Agent context. Route point count and elevation remain.
        output.append(item)
    return output


def _series_rows(
    database: Database,
    metric: str,
    from_date: date,
    to_date: date,
    timezone_name: str,
) -> list[dict[str, Any]]:
    table, column, measured_at = SERIES_METRICS[metric]
    selected = f", {measured_at} AS measured_at" if measured_at else ""
    return database.fetch_all(
        f"""SELECT date, {column} AS value{selected} FROM {table}
             WHERE timezone = ? AND date >= ? AND date <= ? ORDER BY date""",
        (timezone_name, from_date.isoformat(), to_date.isoformat()),
    )


def _trend_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    valid = [(row["date"], float(row["value"])) for row in rows if row.get("value") is not None]
    if not valid:
        return {"status": "missing", "valid_days": 0, "first": None, "latest": None}
    values = [value for _, value in valid]
    first, latest = values[0], values[-1]
    change_percent = ((latest - first) / first * 100) if first else None
    if len(values) < 3 or change_percent is None or abs(change_percent) < 3:
        direction = "stable"
    else:
        direction = "up" if change_percent > 0 else "down"
    return {
        "status": "available",
        "valid_days": len(values),
        "first": first,
        "latest": latest,
        "mean": statistics.fmean(values),
        "median": statistics.median(values),
        "minimum": min(values),
        "maximum": max(values),
        "change_percent_first_to_latest": change_percent,
        "direction": direction,
    }


def _trends(database: Database, target_date: date, timezone_name: str) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for days in (7, 28, 90):
        start = target_date - timedelta(days=days - 1)
        output[f"days_{days}"] = {
            metric: {
                **_trend_summary(
                    _series_rows(database, metric, start, target_date, timezone_name)
                ),
                "unit": METRIC_CATALOG[metric]["unit"],
            }
            for metric in TREND_METRICS
        }
    return output


def _freshness(database: Database) -> dict[str, Any]:
    return database.fetch_all(
        """SELECT MAX(received_at) AS data_as_of, MAX(sample_at) AS latest_sample_at
           FROM (
             SELECT received_at, end_date AS sample_at FROM quantity_samples
             UNION ALL SELECT received_at, end_date FROM category_samples
             UNION ALL SELECT received_at, end_date FROM workouts
           )"""
    )[0]


def _deterministic_signals(insights: dict[str, Any]) -> list[dict[str, Any]]:
    signals: list[dict[str, Any]] = []
    for factor in insights.get("recovery", {}).get("factors", []):
        if factor.get("delta_percent") is None:
            continue
        signals.append({
            "type": "personal_baseline_comparison",
            "metric": factor["key"],
            "current": factor.get("current"),
            "baseline": factor.get("baseline"),
            "delta_percent": factor.get("delta_percent"),
            "signal": factor.get("signal"),
            "interpretation_boundary": "确定性个人基线比较，不是医学诊断或训练处方",
        })
    load = insights.get("training_load", {})
    if load.get("ratio_to_previous_4_week_average") is not None:
        signals.append({
            "type": "training_load_ratio",
            "metric": "load_score",
            "recent_7": load.get("recent_7_load_score"),
            "previous_weekly_average": load.get("previous_4_week_average"),
            "ratio": load.get("ratio_to_previous_4_week_average"),
            "interpretation_boundary": "仅描述相对负荷，不自动生成训练处方",
        })
    return signals


def _metric_status(
    availability: dict[str, Any],
    daily: dict[str, Any] | None,
    sleep: dict[str, Any] | None,
) -> dict[str, dict[str, Any]]:
    mappings = {
        "resting_heart_rate_bpm": ("resting_heart_rate", daily),
        "hrv_sdnn_ms": ("hrv", daily),
        "oxygen_saturation_percent": ("oxygen_saturation", daily),
        "respiratory_rate": ("respiratory_rate", daily),
        "vo2_max": ("vo2_max", daily),
        "heart_rate_recovery_bpm": ("heart_rate_recovery", daily),
        "sleeping_wrist_temperature_c": ("sleeping_wrist_temperature", sleep),
    }
    output: dict[str, dict[str, Any]] = {}
    for metric, (availability_key, values) in mappings.items():
        info = availability.get(availability_key, {})
        value = values.get(metric) if values else None
        reason = None
        if value is not None:
            metric_status = "available"
        elif info.get("support_status") == "unsupported":
            metric_status, reason = "missing", "unsupported"
        elif info.get("support_status") != "unknown" and not info.get("permissions_requested"):
            metric_status, reason = "missing", "permission_not_requested"
        elif info.get("records"):
            metric_status, reason = "missing", "not_measured_today"
        elif info.get("support_status") == "supported":
            metric_status, reason = "missing", "supported_but_no_sample"
        else:
            metric_status, reason = "missing", "never_received"
        output[metric] = {
            "status": metric_status,
            "reason": reason,
            "records_received": int(info.get("records") or 0),
            "last_sample": info.get("last_sample"),
        }
    return output


def build_agent_context(
    database: Database,
    target_date: date,
    timezone_name: str = "Asia/Shanghai",
) -> dict[str, Any]:
    timezone = _validate_timezone(timezone_name)
    daily = _one(database, "normalized_daily_summaries", target_date, timezone_name)
    sleep = _decode_sources(
        _one(database, "normalized_sleep_summaries", target_date, timezone_name)
    )
    if sleep:
        sleep.pop("segments_json", None)
    training = _one(database, "normalized_training_summaries", target_date, timezone_name)
    if training:
        training = dict(training)
        training["training_energy_kcal"] = training.pop("energy_kcal", None)
    workouts = _workouts(database, target_date, timezone_name)
    insights = _dashboard_insights(
        database, target_date, timezone_name, daily, sleep, training
    )
    run = _one(database, "normalization_runs", target_date, timezone_name)
    jobs = database.fetch_all(
        """SELECT status FROM normalization_jobs
           WHERE timezone = ? AND date = ? ORDER BY id DESC LIMIT 1""",
        (timezone_name, target_date.isoformat()),
    )
    pending_jobs = database.fetch_all(
        "SELECT COUNT(*) AS count FROM normalization_jobs WHERE status IN ('pending','running')"
    )[0]["count"]
    gaps = database.fetch_all(
        """SELECT COUNT(*) AS count
           FROM ingest_batches AS current
           WHERE current.status='committed'
             AND current.sequence > 1
             AND NOT EXISTS (
                 SELECT 1
                 FROM ingest_batches AS previous
                 WHERE previous.status='committed'
                   AND previous.owner_id = current.owner_id
                   AND previous.device_id = current.device_id
                   AND previous.sequence = current.sequence - 1
                   AND previous.batch_id = current.previous_batch_id
             )"""
    )[0]["count"]
    today = datetime.now(timezone).date()
    projection_status = jobs[0]["status"] if jobs else ("completed" if run else "unavailable")
    availability = _data_availability(database)
    return {
        "schema_version": AGENT_SCHEMA_VERSION,
        "date": target_date.isoformat(),
        "timezone": timezone_name,
        "generated_at": datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "analysis_day_definition": {
            "activity_and_workouts": "目标日期本地时间 00:00–24:00",
            "sleep": "目标日期前一天 18:00 至目标日期 18:00；最长合并时段为主睡眠，其余为午睡",
        },
        "completeness": {
            **_freshness(database),
            "is_complete_day": target_date < today,
            "projection_available": bool(run),
            "normalization_status": projection_status,
            "pending_normalization_jobs": pending_jobs,
            "sequence_gaps": gaps,
        },
        "activity": {
            key: daily.get(key) if daily else None
            for key in (
                "steps", "walking_running_distance_m", "cycling_distance_m",
                "active_energy_kcal", "basal_energy_kcal", "flights_climbed",
                "exercise_minutes", "stand_hours", "normalized_at",
            )
        },
        "sleep": sleep,
        "cardio_recovery": {
            key: daily.get(key) if daily else None
            for key in (
                "resting_heart_rate_bpm", "walking_heart_rate_bpm", "hrv_sdnn_ms",
                "respiratory_rate", "oxygen_saturation_percent", "vo2_max", "vo2_max_at",
                "heart_rate_recovery_bpm", "heart_rate_recovery_at", "body_mass_kg", "body_mass_at",
            )
        },
        "training_summary": training,
        "workouts": workouts,
        "personal_baselines": insights.get("baseline", {}),
        "regularity": insights.get("regularity", {}),
        "recovery_reference": insights.get("recovery", {}),
        "training_load_context": insights.get("training_load", {}),
        "trends": _trends(database, target_date, timezone_name),
        "deterministic_signals": _deterministic_signals(insights),
        "data_quality": {
            "section_status": {
                "activity": "available" if daily else ("pending" if projection_status in {"pending", "running"} else "missing"),
                "sleep": "available" if sleep else ("pending" if projection_status in {"pending", "running"} else "missing"),
                "training": "available" if training else ("pending" if projection_status in {"pending", "running"} else "missing"),
                "workouts": "available" if workouts else "none_recorded",
            },
            "metric_status": _metric_status(availability, daily, sleep),
            "metric_availability": availability,
            "source_priority": ["Apple Watch", "iPhone", "AutoSleep", "other"],
            "sleep_source_rule": "分期睡眠拥有其覆盖时段；未分期来源只补充未覆盖睡眠",
            "excluded_by_default": ["raw_samples", "raw_metadata", "precise_gps_coordinates"],
        },
        "interpretation_boundary": "Receiver 提供事实、口径和个人基线比较；Agent 的解释不是医学诊断或训练处方。",
    }


def mount_agent_api(app: FastAPI, database: Database) -> None:
    @app.get("/api/v1/agent/catalog", include_in_schema=True)
    def agent_catalog(request: Request) -> dict[str, Any]:
        _require_local_agent(request)
        return {
            "schema_version": AGENT_SCHEMA_VERSION,
            "access": "localhost-only; no token",
            "timezone_default": "Asia/Shanghai",
            "source_priority": ["Apple Watch", "iPhone", "AutoSleep", "other"],
            "metrics": METRIC_CATALOG,
            "workout_fields": WORKOUT_FIELD_CATALOG,
            "series_metrics": sorted(SERIES_METRICS),
            "missing_reasons": {
                "unsupported": "当前设备或系统不支持",
                "permission_not_requested": "App 尚未申请读取权限",
                "supported_but_no_sample": "设备支持，但没有样本或读取未授权",
                "not_measured_today": "历史有该指标，但分析日没有新测量",
                "historical_baseline_insufficient": "有效历史不足，不能可靠比较",
                "normalization_pending": "数据已经到达但物化规整尚未完成",
                "never_received": "Receiver 从未收到此类样本，设备能力也尚不明确",
            },
        }

    @app.get("/api/v1/agent/context/{target_date}", include_in_schema=True)
    def agent_context(
        target_date: date,
        request: Request,
        timezone_name: str = "Asia/Shanghai",
    ) -> dict[str, Any]:
        _require_local_agent(request)
        return build_agent_context(database, target_date, timezone_name)

    @app.get("/api/v1/agent/series/{metric}", include_in_schema=True)
    def agent_series(
        metric: str,
        request: Request,
        from_date: date | None = None,
        to_date: date | None = None,
        timezone_name: str = "Asia/Shanghai",
    ) -> dict[str, Any]:
        _require_local_agent(request)
        timezone = _validate_timezone(timezone_name)
        if metric not in SERIES_METRICS:
            raise HTTPException(
                status_code=404,
                detail={"message": "unsupported metric", "available": sorted(SERIES_METRICS)},
            )
        end = to_date or datetime.now(timezone).date()
        start = from_date or (end - timedelta(days=27))
        if start > end:
            raise HTTPException(status_code=400, detail="from_date must not be after to_date")
        days = (end - start).days + 1
        if days > MAX_SERIES_DAYS:
            raise HTTPException(status_code=400, detail=f"series range is limited to {MAX_SERIES_DAYS} days")
        rows = _series_rows(database, metric, start, end, timezone_name)
        return {
            "schema_version": AGENT_SCHEMA_VERSION,
            "metric": metric,
            "definition": METRIC_CATALOG[metric],
            "timezone": timezone_name,
            "from_date": start.isoformat(),
            "to_date": end.isoformat(),
            "expected_days": days,
            "valid_days": sum(row.get("value") is not None for row in rows),
            "summary": _trend_summary(rows),
            "points": rows,
        }
