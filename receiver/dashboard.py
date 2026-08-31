from __future__ import annotations

import json
import ipaddress
import os
import hmac
import statistics
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse

from .access_control import AccessControl, AccessControlError
from .dashboard_materializer import (
    build_day_snapshot,
    load_data_availability,
    load_day_snapshot,
)
from .database import Database
from .identity import ReceiverIdentity
from .settings import AppPaths
from .version import version_payload


STATIC_DIR = Path(__file__).with_name("static")


def _is_loopback(value: str | None) -> bool:
    if not value:
        return False
    if value.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(value).is_loopback
    except ValueError:
        return False


def _admin_identity(request: Request) -> dict[str, str] | None:
    """Trust the local OS user or the identity asserted by Tailscale Serve.

    Identity headers are accepted only from a loopback proxy. Uvicorn must run
    with proxy-header processing disabled so the socket peer remains the
    loopback Tailscale Serve process; direct LAN clients cannot spoof this path.
    """
    client_host = request.client.host if request.client else None
    if not _is_loopback(client_host):
        return None
    if _is_loopback(request.url.hostname):
        return {"mode": "local", "display_name": "Receiver 本机用户"}
    supplied_login = request.headers.get("tailscale-user-login", "").strip()
    trusted_login = os.environ.get("HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN", "").strip()
    if supplied_login and trusted_login and hmac.compare_digest(
        supplied_login.casefold(), trusted_login.casefold()
    ):
        return {
            "mode": "tailscale",
            "display_name": request.headers.get("tailscale-user-name", supplied_login),
        }
    return None


def _require_dashboard(request: Request) -> dict[str, str]:
    identity = _admin_identity(request)
    if not identity:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="管理页仅允许从 Receiver 本机或已授权的 Tailscale Serve 身份访问",
        )
    return identity


def _access_denied_page() -> str:
    return """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>健康数据面板访问受限</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;
font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif;background:#09110f;color:#eaf7f1}
main{width:min(92vw,420px);padding:34px;border:1px solid #24463c;border-radius:24px;background:#101d19;
box-shadow:0 28px 80px #0008}h1{margin:0 0 8px;font-size:28px}p{color:#99b8ac;line-height:1.6}code{color:#63dfa0}
</style></head><body><main><h1>无需密码，但需要可信入口</h1>
<p>请在 Receiver 电脑打开 <code>http://127.0.0.1:8787/dashboard</code>，或通过配置好的 Tailscale Serve HTTPS 地址访问。</p>
<p>普通局域网和公网请求不能进入管理页面。</p>
</main></body></html>"""


def _receiver_urls(request: Request) -> list[str]:
    configured = [
        value.strip().rstrip("/")
        for value in os.environ.get("HEALTH_RECEIVER_PUBLIC_URLS", "").split(",")
        if value.strip()
    ]
    forwarded_host = request.headers.get("x-forwarded-host")
    forwarded_proto = request.headers.get("x-forwarded-proto")
    if forwarded_host:
        current = f"{forwarded_proto or request.url.scheme}://{forwarded_host}".rstrip("/")
    else:
        current = str(request.base_url).rstrip("/")
    hostname = (request.url.hostname or "").lower()
    if hostname not in {"localhost", "127.0.0.1", "::1"}:
        configured.insert(0, current)
    elif not configured:
        configured.append(current)
    return list(dict.fromkeys(configured))


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


def _median(rows: list[dict[str, Any]], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row.get(key) is not None]
    return statistics.median(values) if values else None


def _delta_percent(current: float | None, baseline: float | None) -> float | None:
    if current is None or baseline in (None, 0):
        return None
    return (float(current) - float(baseline)) / float(baseline) * 100


def _local_clock_minutes(value: str, timezone: ZoneInfo, bedtime: bool = False) -> float:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone)
    minutes = parsed.hour * 60 + parsed.minute + parsed.second / 60
    if bedtime and minutes < 12 * 60:
        minutes += 24 * 60
    return minutes


def _clock_label(minutes: float | None) -> str | None:
    if minutes is None:
        return None
    value = int(round(minutes)) % (24 * 60)
    return f"{value // 60:02d}:{value % 60:02d}"


def _dashboard_insights(
    database: Database,
    target_date: date,
    timezone_name: str,
    daily: dict[str, Any] | None,
    sleep: dict[str, Any] | None,
    training: dict[str, Any] | None,
) -> dict[str, Any]:
    start = target_date - timedelta(days=28)
    previous_day = target_date - timedelta(days=1)
    daily_history = database.fetch_all(
        """SELECT * FROM normalized_daily_summaries
           WHERE timezone = ? AND date >= ? AND date <= ? ORDER BY date""",
        (timezone_name, start.isoformat(), previous_day.isoformat()),
    )
    sleep_history = database.fetch_all(
        """SELECT * FROM normalized_sleep_summaries
           WHERE timezone = ? AND date >= ? AND date <= ?
             AND main_sleep_start IS NOT NULL AND main_sleep_end IS NOT NULL
           ORDER BY date""",
        (timezone_name, start.isoformat(), previous_day.isoformat()),
    )
    training_history = database.fetch_all(
        """SELECT * FROM normalized_training_summaries
           WHERE timezone = ? AND date >= ? AND date <= ? ORDER BY date""",
        (timezone_name, start.isoformat(), previous_day.isoformat()),
    )
    baseline = {
        "main_sleep_minutes": _median(sleep_history, "main_sleep_minutes"),
        "resting_heart_rate_bpm": _median(daily_history, "resting_heart_rate_bpm"),
        "hrv_sdnn_ms": _median(daily_history, "hrv_sdnn_ms"),
        "steps": _median(daily_history, "steps"),
        "active_energy_kcal": _median(daily_history, "active_energy_kcal"),
        "training_load_score": _median(training_history, "load_score"),
        "sleep_days": len(sleep_history),
        "daily_days": len(daily_history),
    }
    timezone = ZoneInfo(timezone_name)
    bedtimes = [
        _local_clock_minutes(row["main_sleep_start"], timezone, bedtime=True)
        for row in sleep_history
    ]
    wake_times = [
        _local_clock_minutes(row["main_sleep_end"], timezone)
        for row in sleep_history
    ]
    bedtime_median = statistics.median(bedtimes) if bedtimes else None
    wake_median = statistics.median(wake_times) if wake_times else None
    regularity = {
        "sample_days": len(bedtimes),
        "usual_bedtime": _clock_label(bedtime_median),
        "usual_wake_time": _clock_label(wake_median),
        "bedtime_variability_minutes": statistics.pstdev(bedtimes) if len(bedtimes) >= 2 else None,
        "wake_variability_minutes": statistics.pstdev(wake_times) if len(wake_times) >= 2 else None,
        "bedtime_deviation_minutes": (
            _local_clock_minutes(sleep["main_sleep_start"], timezone, bedtime=True)
            - bedtime_median
            if sleep and sleep.get("main_sleep_start") and bedtime_median is not None
            else None
        ),
        "wake_deviation_minutes": (
            _local_clock_minutes(sleep["main_sleep_end"], timezone) - wake_median
            if sleep and sleep.get("main_sleep_end") and wake_median is not None
            else None
        ),
    }

    factors: list[dict[str, Any]] = []
    for key, label, current, inverse in (
        (
            "sleep",
            "主睡眠",
            sleep.get("main_sleep_minutes") if sleep else None,
            False,
        ),
        (
            "hrv",
            "HRV",
            daily.get("hrv_sdnn_ms") if daily else None,
            False,
        ),
        (
            "resting_hr",
            "静息心率",
            daily.get("resting_heart_rate_bpm") if daily else None,
            True,
        ),
    ):
        baseline_key = {
            "sleep": "main_sleep_minutes",
            "hrv": "hrv_sdnn_ms",
            "resting_hr": "resting_heart_rate_bpm",
        }[key]
        reference = baseline[baseline_key]
        delta = _delta_percent(current, reference)
        signal = None
        if delta is not None:
            adjusted = -delta if inverse else delta
            signal = 1 if adjusted >= 5 else (-1 if adjusted <= -5 else 0)
        factors.append(
            {
                "key": key,
                "label": label,
                "current": current,
                "baseline": reference,
                "delta_percent": delta,
                "signal": signal,
            }
        )
    available_signals = [item["signal"] for item in factors if item["signal"] is not None]
    signal_total = sum(available_signals)
    if len(available_signals) < 2:
        recovery_status = "insufficient"
        recovery_label = "数据积累中"
    elif signal_total >= 2:
        recovery_status = "positive"
        recovery_label = "恢复信号偏好"
    elif signal_total <= -2:
        recovery_status = "caution"
        recovery_label = "恢复信号偏弱"
    else:
        recovery_status = "stable"
        recovery_label = "恢复信号稳定"
    recent_start = target_date - timedelta(days=6)
    previous_28_start = target_date - timedelta(days=34)
    previous_28_end = target_date - timedelta(days=7)
    recent_training = database.fetch_all(
        """SELECT load_score, workout_minutes, high_intensity_minutes
           FROM normalized_training_summaries
           WHERE timezone = ? AND date >= ? AND date <= ?""",
        (timezone_name, recent_start.isoformat(), target_date.isoformat()),
    )
    previous_training = database.fetch_all(
        """SELECT load_score FROM normalized_training_summaries
           WHERE timezone = ? AND date >= ? AND date <= ?""",
        (timezone_name, previous_28_start.isoformat(), previous_28_end.isoformat()),
    )
    recent_load = sum(float(row["load_score"]) for row in recent_training)
    # A newly installed Receiver may not yet have all 28 baseline days. Scale
    # the available daily load to a weekly average instead of treating missing
    # days as zero, but wait for at least two weeks before showing a comparison.
    previous_active_days = sum(
        1 for row in previous_training if float(row["load_score"]) > 0
    )
    previous_weekly_load = (
        sum(float(row["load_score"]) for row in previous_training)
        * 7
        / len(previous_training)
        if len(previous_training) >= 14 and previous_active_days >= 3
        else None
    )
    return {
        "baseline": baseline,
        "regularity": regularity,
        "recovery": {
            "status": recovery_status,
            "label": recovery_label,
            "factors": factors,
            "note": "仅比较个人近 28 天基线，不是医学诊断或训练处方。",
        },
        "training_load": {
            "today_load_score": float(training.get("load_score") or 0) if training else 0,
            "recent_7_load_score": recent_load,
            "recent_7_workout_minutes": sum(
                float(row["workout_minutes"]) for row in recent_training
            ),
            "recent_7_high_intensity_minutes": sum(
                float(row["high_intensity_minutes"]) for row in recent_training
            ),
            "previous_4_week_average": previous_weekly_load,
            "baseline_calendar_days": len(previous_training),
            "baseline_active_days": previous_active_days,
            "ratio_to_previous_4_week_average": (
                recent_load / previous_weekly_load
                if previous_weekly_load and previous_weekly_load > 0
                else None
            ),
            "method": "Z1–Z5 分钟分别乘以 1–5 后相加；无心率覆盖的训练只计时长。",
        },
    }


def _data_availability(database: Database) -> dict[str, Any]:
    return load_data_availability(database)


def _available_dates(database: Database) -> dict[str, str | None]:
    row = database.fetch_all(
        """SELECT MIN(date) AS first_date, MAX(date) AS last_date
           FROM normalization_runs WHERE timezone = 'Asia/Shanghai'"""
    )[0]
    return {"first": row["first_date"], "last": row["last_date"]}


def _route_previews(database: Database, workout_ids: list[str]) -> dict[str, list[dict[str, float]]]:
    if not workout_ids:
        return {}
    placeholders = ", ".join("?" for _ in workout_ids)
    output: dict[str, list[dict[str, float]]] = {}
    points = database.fetch_all(
        f"""SELECT workout_uuid, latitude, longitude
            FROM route_points WHERE workout_uuid IN ({placeholders})
            ORDER BY workout_uuid, timestamp, point_index""",
        workout_ids,
    )
    for point in points:
        output.setdefault(point["workout_uuid"], []).append(
            {"latitude": point["latitude"], "longitude": point["longitude"]}
        )
    legacy = database.fetch_all(
        f"""SELECT workout_uuid, locations_json FROM workout_routes
            WHERE workout_uuid IN ({placeholders}) ORDER BY start_date""",
        workout_ids,
    )
    for row in legacy:
        if output.get(row["workout_uuid"]) or not row.get("locations_json"):
            continue
        try:
            locations = json.loads(row["locations_json"])
        except (TypeError, json.JSONDecodeError):
            continue
        output[row["workout_uuid"]] = [
            {"latitude": float(item["latitude"]), "longitude": float(item["longitude"])}
            for item in locations
            if isinstance(item, dict) and "latitude" in item and "longitude" in item
        ]
    for workout_id, route in list(output.items()):
        if len(route) > 600:
            stride = max(len(route) // 600, 1)
            sampled = route[::stride]
            if sampled[-1] != route[-1]:
                sampled.append(route[-1])
            output[workout_id] = sampled
    return output


def mount_dashboard(
    app: FastAPI,
    database: Database,
    access: AccessControl,
    identity: ReceiverIdentity,
    paths: AppPaths | None = None,
) -> None:
    @app.get("/dashboard/setup", response_class=HTMLResponse, include_in_schema=False)
    def dashboard_setup_page() -> RedirectResponse:
        return RedirectResponse("/dashboard", status_code=303)

    @app.post("/dashboard/setup", include_in_schema=False)
    def dashboard_setup_legacy() -> RedirectResponse:
        return RedirectResponse("/dashboard", status_code=303)

    @app.get("/dashboard", response_class=HTMLResponse, include_in_schema=False)
    def dashboard(request: Request):
        if not _admin_identity(request):
            return HTMLResponse(_access_denied_page(), status_code=403)
        return HTMLResponse((STATIC_DIR / "dashboard.html").read_text(encoding="utf-8"))

    @app.post("/dashboard/login", include_in_schema=False)
    def dashboard_login_legacy() -> RedirectResponse:
        return RedirectResponse("/dashboard", status_code=303)

    @app.post("/dashboard/logout", include_in_schema=False)
    def dashboard_logout_legacy() -> RedirectResponse:
        return RedirectResponse("/dashboard", status_code=303)

    @app.get("/api/v2/admin/status", include_in_schema=False)
    def admin_status(request: Request) -> dict[str, Any]:
        identity_data = _admin_identity(request)
        return {
            "authentication": "local-os-or-tailscale-identity",
            "authorized": identity_data is not None,
            "identity": identity_data,
        }

    @app.post("/api/v2/admin/pairing-sessions", include_in_schema=False)
    def create_pairing_session(request: Request) -> dict[str, Any]:
        _require_dashboard(request)
        pairing = access.create_pairing_session()
        receiver_urls = _receiver_urls(request)
        pairing.update(
            {
                "receiver_url": receiver_urls[0],
                "receiver_urls": receiver_urls,
                "receiver": identity.pairing_payload(),
            }
        )
        return pairing

    @app.get("/api/v2/admin/pairing-requests", include_in_schema=False)
    def pending_pairing_requests(request: Request) -> dict[str, Any]:
        _require_dashboard(request)
        return {"requests": access.pending_local_pairing_requests()}

    @app.post("/api/v2/admin/pairing-requests/{request_id}/approve", include_in_schema=False)
    def approve_pairing_request(request_id: str, request: Request) -> dict[str, Any]:
        _require_dashboard(request)
        try:
            return access.resolve_local_pairing_request(request_id, approve=True)
        except (ValueError, AccessControlError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/v2/admin/pairing-requests/{request_id}/reject", include_in_schema=False)
    def reject_pairing_request(request_id: str, request: Request) -> dict[str, Any]:
        _require_dashboard(request)
        try:
            return access.resolve_local_pairing_request(request_id, approve=False)
        except (ValueError, AccessControlError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.get("/api/v1/dashboard/status", include_in_schema=False)
    def dashboard_status(request: Request) -> dict[str, Any]:
        admin_identity = _require_dashboard(request)
        latest_received = [
            row["received_at"]
            for table in ("quantity_samples", "category_samples", "workouts")
            for row in database.fetch_all(
                f"SELECT received_at FROM {table} ORDER BY rowid DESC LIMIT 1"
            )
            if row.get("received_at")
        ]
        freshness = {"last_received_at": max(latest_received, default=None)}
        return {
            "version": version_payload(),
            "admin_identity": admin_identity,
            "available_dates": _available_dates(database),
            "freshness": freshness,
            "counts": {
                # Dashboard counters are informational. MAX(rowid) is an O(1)
                # high-water mark and avoids rescanning a multi-gigabyte raw
                # table every five seconds while a historical import runs.
                table: database.fetch_all(
                    f"SELECT COALESCE(MAX(rowid), 0) AS value FROM {table}"
                )[0]["value"]
                for table in ("quantity_samples", "category_samples", "workouts", "workout_routes")
            },
            "encrypted_sync": {
                "devices": database.fetch_all(
                    """SELECT device_id, display_name, status, last_sequence, last_seen_at
                       FROM devices ORDER BY last_seen_at DESC"""
                ),
                "batches": database.fetch_all(
                    """SELECT COUNT(*) AS total,
                              (
                                  SELECT COUNT(*)
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
                                    )
                              ) AS gaps,
                              MAX(committed_at) AS last_committed_at
                       FROM ingest_batches WHERE status='committed'"""
                )[0],
                "pending_normalization": database.fetch_all(
                    "SELECT COUNT(*) AS count FROM normalization_jobs WHERE status IN ('pending','running')"
                )[0]["count"],
                "cloud_relay": {
                    "configured_devices": len(list(paths.keys.glob("cloud-relay-*.json"))) if paths else 0,
                    "objects": database.fetch_all(
                        """SELECT COUNT(*) AS total,
                                  SUM(CASE WHEN status='committed' THEN 1 ELSE 0 END) AS committed,
                                  SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) AS failed,
                                  MAX(processed_at) AS last_processed_at
                           FROM cloud_relay_objects"""
                    )[0],
                },
            },
        }

    @app.get("/api/v1/dashboard/day/{target_date}", include_in_schema=False)
    def dashboard_day(
        target_date: date,
        request: Request,
        timezone_name: str = "Asia/Shanghai",
    ) -> dict[str, Any]:
        _require_dashboard(request)
        try:
            ZoneInfo(timezone_name)
        except Exception as exc:
            raise HTTPException(status_code=400, detail="invalid timezone") from exc
        run_rows = database.fetch_all(
            "SELECT normalized_at FROM normalization_runs WHERE timezone = ? AND date = ?",
            (timezone_name, target_date.isoformat()),
        )
        job_rows = database.fetch_all(
            """SELECT status FROM normalization_jobs
               WHERE timezone = ? AND date = ? ORDER BY id DESC LIMIT 1""",
            (timezone_name, target_date.isoformat()),
        )
        projection_status = job_rows[0]["status"] if job_rows else (
            "completed" if run_rows else "unavailable"
        )
        payload = load_day_snapshot(database, target_date, timezone_name)
        if payload is None:
            live = build_day_snapshot(database, target_date, timezone_name)
            payload = live[0] if live else {
                "date": target_date.isoformat(),
                "timezone": timezone_name,
                "daily": None,
                "sleep": None,
                "sleep_segments": [],
                "workouts": [],
                "training": None,
                "heart_rate": [],
                "quantity_minutes": [],
                "insights": {},
            }
        payload["availability"] = _data_availability(database)
        payload["projection"] = {
            "available": bool(run_rows),
            "status": projection_status,
            "normalized_at": run_rows[0]["normalized_at"] if run_rows else None,
        }
        return payload

    @app.get("/api/v1/dashboard/trends", include_in_schema=False)
    def dashboard_trends(
        request: Request,
        days: int = 14,
        end_date: date | None = None,
        timezone_name: str = "Asia/Shanghai",
    ) -> dict[str, Any]:
        _require_dashboard(request)
        days = min(max(days, 1), 90)
        end = end_date or datetime.now(ZoneInfo(timezone_name)).date()
        start = end - timedelta(days=days - 1)
        daily = database.fetch_all(
            """SELECT * FROM normalized_daily_summaries
               WHERE timezone = ? AND date >= ? AND date <= ? ORDER BY date""",
            (timezone_name, start.isoformat(), end.isoformat()),
        )
        sleep = database.fetch_all(
            """SELECT * FROM normalized_sleep_summaries
               WHERE timezone = ? AND date >= ? AND date <= ? ORDER BY date""",
            (timezone_name, start.isoformat(), end.isoformat()),
        )
        training = database.fetch_all(
            """SELECT * FROM normalized_training_summaries
               WHERE timezone = ? AND date >= ? AND date <= ? ORDER BY date""",
            (timezone_name, start.isoformat(), end.isoformat()),
        )
        by_date = {row["date"]: row for row in sleep}
        training_by_date = {row["date"]: row for row in training}
        return {
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "days": [
                {
                    "date": row["date"],
                    "daily": row,
                    "sleep": _decode_sources(by_date.get(row["date"])),
                    "training": training_by_date.get(row["date"]),
                }
                for row in daily
            ],
        }

    @app.get("/api/v1/dashboard/types", include_in_schema=False)
    def dashboard_types(request: Request) -> dict[str, Any]:
        _require_dashboard(request)
        return {
            "quantity": database.fetch_all(
                """SELECT type, COUNT(*) AS records, MIN(start_date) AS first_sample,
                          MAX(end_date) AS last_sample, COUNT(DISTINCT source_name) AS sources
                   FROM quantity_samples GROUP BY type ORDER BY type"""
            ),
            "categories": database.fetch_all(
                """SELECT type, COUNT(*) AS records, MIN(start_date) AS first_sample,
                          MAX(end_date) AS last_sample, COUNT(DISTINCT source_name) AS sources
                   FROM category_samples GROUP BY type ORDER BY type"""
            ),
        }
