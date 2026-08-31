from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
from datetime import date, datetime
from pathlib import Path

from fastapi.testclient import TestClient

from receiver.app import create_app
from receiver.dashboard_materializer import DashboardMaterializer
from receiver.exporter import export_day
from receiver.normalizer import normalize_day, normalized_sleep_segments
from receiver.worker import (
    CLOUD_RELAY_WORKER,
    NORMALIZATION_WORKER,
    update_worker_heartbeat,
)


TOKEN = "normalizer-test-token"


class NormalizerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        os.environ["HEALTH_RECEIVER_TOKEN_SHA256"] = hashlib.sha256(TOKEN.encode()).hexdigest()
        os.environ["HEALTH_RECEIVER_TRUSTED_TAILSCALE_LOGIN"] = "owner@example.com"
        self.app = create_app(Path(self.tempdir.name) / "test.sqlite3")
        self.database = self.app.state.database
        self.client = TestClient(
            self.app,
            base_url="http://127.0.0.1",
            client=("127.0.0.1", 50000),
        )
        self.headers = {"Authorization": f"Bearer {TOKEN}"}

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def ingest_quantities(self, records: list[dict]) -> None:
        response = self.client.post(
            "/api/v1/healthbeat/quantity-samples",
            json={"records": records},
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 200, response.text)

    def ingest_sleep(self, records: list[dict]) -> None:
        response = self.client.post(
            "/api/v1/healthbeat/category-samples",
            json={"records": records},
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 200, response.text)

    def test_source_priority_uses_watch_then_phone_only_minutes(self) -> None:
        self.ingest_quantities(
            [
                {
                    "uuid": "watch-overlap",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "value": 100,
                    "unit": "count",
                    "start_date": "2026-08-27T00:00:00Z",
                    "end_date": "2026-08-27T00:01:00Z",
                    "source_name": "My Apple Watch",
                    "device_name": "Apple Watch",
                },
                {
                    "uuid": "phone-overlap",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "value": 80,
                    "unit": "count",
                    "start_date": "2026-08-27T00:00:00Z",
                    "end_date": "2026-08-27T00:01:00Z",
                    "source_name": "My iPhone",
                    "device_name": "iPhone",
                },
                {
                    "uuid": "phone-only",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "value": 50,
                    "unit": "count",
                    "start_date": "2026-08-27T00:01:00Z",
                    "end_date": "2026-08-27T00:02:00Z",
                    "source_name": "My iPhone",
                    "device_name": "iPhone",
                },
            ]
        )
        result = normalize_day(self.database, date(2026, 8, 27))
        self.assertEqual(result["daily"]["steps"], 150)
        rows = self.database.fetch_all(
            """SELECT minute, value, source_name FROM normalized_quantity_minutes
               WHERE type = 'HKQuantityTypeIdentifierStepCount' ORDER BY minute"""
        )
        self.assertEqual([(row["value"], row["source_name"]) for row in rows], [(100, "My Apple Watch"), (50, "My iPhone")])

    def test_sleep_prefers_stages_and_keeps_uncovered_autosleep_nap(self) -> None:
        common = {"type": "HKCategoryTypeIdentifierSleepAnalysis", "value": 3}
        self.ingest_sleep(
            [
                {
                    **common,
                    "uuid": "autosleep-main",
                    "value_label": "Asleep Unspecified",
                    "start_date": "2026-08-26T15:00:00Z",
                    "end_date": "2026-08-26T22:00:00Z",
                    "source_name": "AutoSleep",
                },
                {
                    **common,
                    "uuid": "watch-core-1",
                    "value_label": "Asleep Core",
                    "start_date": "2026-08-26T15:00:00Z",
                    "end_date": "2026-08-26T18:00:00Z",
                    "source_name": "My Apple Watch",
                    "device_name": "Apple Watch",
                },
                {
                    **common,
                    "uuid": "watch-awake",
                    "value_label": "Awake",
                    "start_date": "2026-08-26T18:00:00Z",
                    "end_date": "2026-08-26T18:10:00Z",
                    "source_name": "My Apple Watch",
                    "device_name": "Apple Watch",
                },
                {
                    **common,
                    "uuid": "watch-core-2",
                    "value_label": "Asleep Core",
                    "start_date": "2026-08-26T18:10:00Z",
                    "end_date": "2026-08-26T22:00:00Z",
                    "source_name": "My Apple Watch",
                    "device_name": "Apple Watch",
                },
                {
                    **common,
                    "uuid": "autosleep-nap",
                    "value_label": "Asleep Unspecified",
                    "start_date": "2026-08-27T05:00:00Z",
                    "end_date": "2026-08-27T05:30:00Z",
                    "source_name": "AutoSleep",
                },
            ]
        )
        sleep = normalize_day(self.database, date(2026, 8, 27))["sleep"]
        self.assertAlmostEqual(sleep["core_minutes"], 410)
        self.assertAlmostEqual(sleep["awake_minutes"], 10)
        self.assertAlmostEqual(sleep["main_sleep_minutes"], 410)
        self.assertAlmostEqual(sleep["nap_minutes"], 30)
        self.assertAlmostEqual(sleep["total_asleep_minutes"], 440)
        rows = self.database.fetch_all(
            "SELECT * FROM category_samples ORDER BY start_date"
        )
        segments = normalized_sleep_segments(
            rows,
            datetime.fromisoformat("2026-08-26T10:00:00+00:00"),
            datetime.fromisoformat("2026-08-27T10:00:00+00:00"),
        )
        self.assertEqual(
            sum(
                (datetime.fromisoformat(row["end_date"].replace("Z", "+00:00"))
                 - datetime.fromisoformat(row["start_date"].replace("Z", "+00:00"))).total_seconds()
                for row in segments
                if row["source_name"] == "AutoSleep"
            ) / 60,
            30,
        )
        self.assertIn("AutoSleep", sleep["sources_json"])
        exported = export_day(self.database, date(2026, 8, 27))
        self.assertTrue(exported["sleep_samples"])
        self.assertTrue(
            any(row["source_name"] == "AutoSleep" for row in exported["sleep_samples"])
        )

    def test_unspecified_sleep_is_valid_without_a_stage_capable_device(self) -> None:
        self.ingest_sleep(
            [
                {
                    "uuid": "generic-main",
                    "type": "HKCategoryTypeIdentifierSleepAnalysis",
                    "value": 3,
                    "value_label": "Asleep Unspecified",
                    "start_date": "2026-08-26T15:00:00Z",
                    "end_date": "2026-08-26T22:00:00Z",
                    "source_name": "Generic Sleep Tracker",
                }
            ]
        )
        sleep = normalize_day(self.database, date(2026, 8, 27))["sleep"]
        self.assertAlmostEqual(sleep["main_sleep_minutes"], 420)
        self.assertAlmostEqual(sleep["unspecified_minutes"], 420)
        self.assertEqual(sleep["session_count"], 1)

    def test_sleep_efficiency_uses_in_bed_and_keeps_continuity_separate(self) -> None:
        common = {"type": "HKCategoryTypeIdentifierSleepAnalysis", "value": 3}
        self.ingest_quantities(
            [
                {
                    "uuid": "sleep-heart",
                    "type": "HKQuantityTypeIdentifierHeartRate",
                    "value": 58,
                    "unit": "bpm",
                    "start_date": "2026-08-26T18:00:00Z",
                    "end_date": "2026-08-26T18:00:01Z",
                    "source_name": "Future Sleep Ring",
                },
                {
                    "uuid": "sleep-oxygen",
                    "type": "HKQuantityTypeIdentifierOxygenSaturation",
                    "value": 0.96,
                    "unit": "%",
                    "start_date": "2026-08-26T19:00:00Z",
                    "end_date": "2026-08-26T19:00:01Z",
                    "source_name": "Future Sleep Ring",
                },
            ]
        )
        self.ingest_sleep(
            [
                {
                    **common,
                    "uuid": "in-bed",
                    "value_label": "In Bed",
                    "start_date": "2026-08-26T15:00:00Z",
                    "end_date": "2026-08-26T23:00:00Z",
                    "source_name": "Sleep Schedule",
                },
                {
                    **common,
                    "uuid": "asleep",
                    "value_label": "Asleep Core",
                    "start_date": "2026-08-26T15:30:00Z",
                    "end_date": "2026-08-26T22:30:00Z",
                    "source_name": "Future Sleep Ring",
                },
            ]
        )
        sleep = normalize_day(self.database, date(2026, 8, 27))["sleep"]
        self.assertAlmostEqual(sleep["sleep_efficiency"], 420 / 480)
        self.assertAlmostEqual(sleep["sleep_continuity"], 1.0)
        self.assertEqual(sleep["sleep_efficiency_basis"], "in_bed")
        self.assertEqual(sleep["sleeping_heart_rate_avg_bpm"], 58)
        self.assertEqual(sleep["sleeping_oxygen_avg_percent"], 96)

    def test_workout_materializes_personal_heart_rate_zones(self) -> None:
        records = [
            {
                "uuid": "resting",
                "type": "HKQuantityTypeIdentifierRestingHeartRate",
                "value": 60,
                "unit": "bpm",
                "start_date": "2026-08-26T02:00:00Z",
                "end_date": "2026-08-26T02:00:01Z",
                "source_name": "My Apple Watch",
            },
            {
                "uuid": "historical-maximum",
                "type": "HKQuantityTypeIdentifierHeartRate",
                "value": 180,
                "unit": "bpm",
                "start_date": "2026-08-26T03:00:00Z",
                "end_date": "2026-08-26T03:00:01Z",
                "source_name": "My Apple Watch",
            },
        ]
        for index, value in enumerate((100, 135, 150, 160, 175)):
            records.append(
                {
                    "uuid": f"workout-heart-{index}",
                    "type": "HKQuantityTypeIdentifierHeartRate",
                    "value": value,
                    "unit": "bpm",
                    "start_date": f"2026-08-27T02:0{index}:00Z",
                    "end_date": f"2026-08-27T02:0{index}:01Z",
                    "source_name": "My Apple Watch",
                }
            )
        self.ingest_quantities(records)
        response = self.client.post(
            "/api/v1/healthbeat/workouts",
            json={
                "records": [
                    {
                        "uuid": "zoned-workout",
                        "activity_type": "running",
                        "duration_seconds": 300,
                        "start_date": "2026-08-27T02:00:00Z",
                        "end_date": "2026-08-27T02:05:00Z",
                        "source_name": "My Apple Watch",
                    }
                ]
            },
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 200, response.text)
        normalize_day(self.database, date(2026, 8, 27))
        row = self.database.fetch_all(
            "SELECT heart_rate_zones_json, heart_rate_zone_method FROM normalized_workouts"
        )[0]
        zones = json.loads(row["heart_rate_zones_json"])
        self.assertEqual(row["heart_rate_zone_method"], "personal-heart-rate-reserve-observed-v1")
        self.assertEqual([zones["minutes"][f"zone_{i}"] for i in range(1, 6)], [1, 1, 1, 1, 1])
        training = self.database.fetch_all("SELECT * FROM normalized_training_summaries")[0]
        self.assertEqual(training["workout_minutes"], 5)
        self.assertEqual(training["high_intensity_minutes"], 2)
        self.assertEqual(training["load_score"], 15)
        dashboard = self.client.get("/api/v1/dashboard/day/2026-08-27").json()
        self.assertEqual(
            dashboard["workouts"][0]["heart_rate_zones"]["minutes"]["zone_5"], 1
        )

    def test_stage_semantics_do_not_depend_on_watch_source_name(self) -> None:
        common = {"type": "HKCategoryTypeIdentifierSleepAnalysis", "value": 3}
        self.ingest_sleep(
            [
                {
                    **common,
                    "uuid": "ring-core",
                    "value_label": "Asleep Core",
                    "start_date": "2026-08-26T15:00:00Z",
                    "end_date": "2026-08-26T22:00:00Z",
                    "source_name": "Future Sleep Ring",
                },
                {
                    **common,
                    "uuid": "generic-overlap",
                    "value_label": "Asleep Unspecified",
                    "start_date": "2026-08-26T14:50:00Z",
                    "end_date": "2026-08-26T22:10:00Z",
                    "source_name": "Another Sleep App",
                },
            ]
        )
        sleep = normalize_day(self.database, date(2026, 8, 27))["sleep"]
        self.assertAlmostEqual(sleep["main_sleep_minutes"], 420)
        self.assertAlmostEqual(sleep["unspecified_minutes"], 0)

    def test_daily_summary_carries_latest_vo2_max_forward(self) -> None:
        self.ingest_quantities(
            [
                {
                    "uuid": "vo2-old",
                    "type": "HKQuantityTypeIdentifierVO2Max",
                    "value": 40.03,
                    "unit": "mL/kg·min",
                    "start_date": "2026-08-26T12:17:03Z",
                    "end_date": "2026-08-26T12:17:03Z",
                    "source_name": "My Apple Watch",
                }
            ]
        )
        daily = normalize_day(self.database, date(2026, 8, 27))["daily"]
        self.assertEqual(daily["vo2_max"], 40.03)
        self.assertEqual(daily["vo2_max_at"], "2026-08-26T12:17:03.000Z")

    def test_body_composition_uses_healthkit_values_and_calculates_missing_fields(self) -> None:
        self.ingest_quantities(
            [
                {
                    "uuid": "body-weight",
                    "type": "HKQuantityTypeIdentifierBodyMass",
                    "value": 70,
                    "unit": "kg",
                    "start_date": "2026-08-27T02:00:00Z",
                    "end_date": "2026-08-27T02:00:01Z",
                    "source_name": "Huawei Health",
                },
                {
                    "uuid": "body-fat",
                    "type": "HKQuantityTypeIdentifierBodyFatPercentage",
                    "value": 0.2,
                    "unit": "%",
                    "start_date": "2026-08-27T02:00:00Z",
                    "end_date": "2026-08-27T02:00:01Z",
                    "source_name": "Huawei Health",
                },
                {
                    "uuid": "body-height",
                    "type": "HKQuantityTypeIdentifierHeight",
                    "value": 1.75,
                    "unit": "m",
                    "start_date": "2026-01-01T02:00:00Z",
                    "end_date": "2026-01-01T02:00:01Z",
                    "source_name": "Health",
                },
            ]
        )
        daily = normalize_day(self.database, date(2026, 8, 27))["daily"]
        self.assertEqual(daily["body_mass_kg"], 70)
        self.assertEqual(daily["body_fat_percent"], 20)
        self.assertAlmostEqual(daily["body_mass_index"], 70 / (1.75 ** 2))
        self.assertEqual(daily["body_mass_index_source"], "calculated")
        self.assertAlmostEqual(daily["lean_body_mass_kg"], 56)
        self.assertEqual(daily["lean_body_mass_source"], "calculated")

        context = self.client.get("/api/v1/agent/context/2026-08-27").json()
        self.assertEqual(context["body"]["body_mass_kg"], 70)
        self.assertEqual(context["body"]["body_fat_percent"], 20)
        self.assertEqual(context["data_quality"]["section_status"]["body"], "available")
        self.assertEqual(
            context["data_quality"]["metric_status"]["body_mass_index"]["status"],
            "available",
        )
        self.assertEqual(
            context["data_quality"]["metric_status"]["lean_body_mass_kg"]["status"],
            "available",
        )

    def test_body_composition_expires_after_thirty_days_but_height_remains_reusable(self) -> None:
        self.ingest_quantities(
            [
                {
                    "uuid": "stale-body-weight",
                    "type": "HKQuantityTypeIdentifierBodyMass",
                    "value": 70,
                    "unit": "kg",
                    "start_date": "2022-08-01T02:00:00Z",
                    "end_date": "2022-08-01T02:00:01Z",
                    "source_name": "Huawei Health",
                },
                {
                    "uuid": "persistent-height",
                    "type": "HKQuantityTypeIdentifierHeight",
                    "value": 1.75,
                    "unit": "m",
                    "start_date": "2022-08-01T02:00:00Z",
                    "end_date": "2022-08-01T02:00:01Z",
                    "source_name": "Health",
                },
            ]
        )

        stale = normalize_day(self.database, date(2026, 8, 1))["daily"]
        self.assertIsNone(stale["body_mass_kg"])
        self.assertIsNone(stale["body_mass_at"])
        self.assertIsNone(stale["body_mass_index"])

        self.ingest_quantities(
            [
                {
                    "uuid": "fresh-body-weight",
                    "type": "HKQuantityTypeIdentifierBodyMass",
                    "value": 68,
                    "unit": "kg",
                    "start_date": "2026-07-15T02:00:00Z",
                    "end_date": "2026-07-15T02:00:01Z",
                    "source_name": "Huawei Health",
                }
            ]
        )
        fresh = normalize_day(self.database, date(2026, 8, 1))["daily"]
        self.assertEqual(fresh["body_mass_kg"], 68)
        self.assertAlmostEqual(fresh["body_mass_index"], 68 / (1.75 ** 2))
        self.assertEqual(fresh["body_mass_index_source"], "calculated")

    def test_export_v2_uses_separate_normalized_layer_without_sleep_duplication(self) -> None:
        self.ingest_sleep(
            [
                {
                    "uuid": "sleep-only",
                    "type": "HKCategoryTypeIdentifierSleepAnalysis",
                    "value": 3,
                    "value_label": "Asleep Core",
                    "start_date": "2026-08-26T15:00:00Z",
                    "end_date": "2026-08-26T22:00:00Z",
                    "source_name": "My Apple Watch",
                }
            ]
        )
        normalize_day(self.database, date(2026, 8, 27))
        payload = export_day(self.database, date(2026, 8, 27))
        self.assertEqual(payload["schema_version"], 2)
        self.assertEqual(payload["category_samples"], [])
        self.assertEqual(len(payload["sleep_samples"]), 1)
        self.assertEqual(payload["normalized"]["sleep_summary"]["core_minutes"], 420)

    def test_dashboard_trusts_local_os_or_expected_tailscale_identity_only(self) -> None:
        local_dashboard = self.client.get("/dashboard")
        self.assertEqual(local_dashboard.status_code, 200)
        self.assertIn("健康数据面板", local_dashboard.text)
        self.assertIn("'elliptical':'椭圆机训练'", local_dashboard.text)
        self.assertIn("workoutTypeLabel(w.activity_type)", local_dashboard.text)
        self.assertIn("近 30 天有效 · 低频长期指标", local_dashboard.text)
        self.assertIn("function smoothSeries", local_dashboard.text)
        self.assertIn("function installChartInteraction", local_dashboard.text)
        self.assertIn("平滑趋势", local_dashboard.text)
        self.assertIn('id="bodyPanel"', local_dashboard.text)
        self.assertNotIn("metric('体重'", local_dashboard.text)
        dashboard_status = self.client.get("/api/v1/dashboard/status")
        self.assertEqual(dashboard_status.status_code, 200)
        self.assertEqual(
            dashboard_status.json()["version"]["product_version"],
            "0.1.0-beta.1",
        )
        pairing = self.client.post("/api/v2/admin/pairing-sessions")
        self.assertEqual(pairing.status_code, 200)
        self.assertRegex(pairing.json()["pairing_code"], r"^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$")

        tailscale = TestClient(
            self.app,
            base_url="https://receiver.example.ts.net",
            client=("127.0.0.1", 50001),
            headers={
                "Tailscale-User-Login": "owner@example.com",
                "Tailscale-User-Name": "=?utf-8?q?=E4=B9=8B=E9=97=B4=E8=93=AC=E8=92=BF?=",
            },
        )
        self.assertEqual(tailscale.get("/dashboard").status_code, 200)
        tailscale_status = tailscale.get("/api/v2/admin/status").json()["identity"]
        self.assertEqual(tailscale_status["mode"], "tailscale")
        self.assertEqual(tailscale_status["display_name"], "之间蓬蒿")

        wrong_identity = TestClient(
            self.app,
            base_url="https://receiver.example.ts.net",
            client=("127.0.0.1", 50002),
            headers={"Tailscale-User-Login": "someone-else@example.com"},
        )
        self.assertEqual(wrong_identity.get("/dashboard").status_code, 403)

        spoofed_lan = TestClient(
            self.app,
            base_url="http://10.0.0.5:8787",
            client=("10.0.0.20", 50003),
            headers={"Tailscale-User-Login": "owner@example.com"},
        )
        self.assertEqual(spoofed_lan.get("/dashboard").status_code, 403)
        self.assertEqual(spoofed_lan.post("/api/v2/admin/pairing-sessions").status_code, 403)

    def test_dashboard_reads_materialized_results_without_normalizing_on_request(self) -> None:
        self.ingest_quantities(
            [
                {
                    "uuid": "dashboard-steps",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "value": 321,
                    "unit": "count",
                    "start_date": "2026-08-27T00:00:00Z",
                    "end_date": "2026-08-27T00:01:00Z",
                    "source_name": "My Apple Watch",
                }
            ]
        )

        before = self.client.get("/api/v1/dashboard/day/2026-08-27")
        self.assertEqual(before.status_code, 200)
        self.assertIsNone(before.json()["daily"])
        self.assertFalse(before.json()["projection"]["available"])
        self.assertEqual(
            self.database.fetch_all("SELECT COUNT(*) AS count FROM normalization_runs")[0]["count"],
            0,
        )

        normalize_day(self.database, date(2026, 8, 27))
        after = self.client.get("/api/v1/dashboard/day/2026-08-27")
        self.assertEqual(after.status_code, 200)
        self.assertEqual(after.json()["daily"]["steps"], 321)
        self.assertTrue(after.json()["projection"]["available"])
        self.assertIn("recovery", after.json()["insights"])
        self.assertEqual(after.json()["availability"]["heart_rate"]["records"], 0)

    def test_dashboard_day_is_served_from_a_rebuildable_snapshot(self) -> None:
        self.ingest_quantities(
            [
                {
                    "uuid": "snapshot-steps",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "value": 321,
                    "unit": "count",
                    "start_date": "2026-08-27T00:00:00Z",
                    "end_date": "2026-08-27T00:01:00Z",
                    "source_name": "My Apple Watch",
                }
            ]
        )
        normalize_day(self.database, date(2026, 8, 27))
        result = DashboardMaterializer(self.database).run_once()
        self.assertEqual(result.failed, 0)
        self.assertEqual(
            self.database.fetch_all(
                "SELECT COUNT(*) AS count FROM dashboard_day_snapshots"
            )[0]["count"],
            1,
        )
        with self.database.connection() as connection:
            connection.execute(
                "DELETE FROM normalized_daily_summaries WHERE timezone=? AND date=?",
                ("Asia/Shanghai", "2026-08-27"),
            )
        response = self.client.get("/api/v1/dashboard/day/2026-08-27")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["daily"]["steps"], 321)

    def test_external_worker_readiness_uses_persisted_heartbeats(self) -> None:
        previous = os.environ.get("HEALTH_RECEIVER_WORKERS_EXTERNAL")
        os.environ["HEALTH_RECEIVER_WORKERS_EXTERNAL"] = "1"
        try:
            app = create_app(Path(self.tempdir.name) / "external.sqlite3")
            client = TestClient(
                app,
                base_url="http://127.0.0.1",
                client=("127.0.0.1", 50009),
            )
            self.assertEqual(client.get("/api/v1/healthbeat/ready").status_code, 503)
            update_worker_heartbeat(
                app.state.database,
                NORMALIZATION_WORKER,
                "idle",
                success=True,
            )
            update_worker_heartbeat(
                app.state.database,
                CLOUD_RELAY_WORKER,
                "idle",
                success=True,
            )
            payload = client.get("/api/v1/healthbeat/ready")
            self.assertEqual(payload.status_code, 200)
            self.assertEqual(payload.json()["normalization_worker_status"], "idle")
            self.assertEqual(payload.json()["cloud_relay_worker_status"], "idle")
            update_worker_heartbeat(
                app.state.database,
                NORMALIZATION_WORKER,
                "error",
                error="snapshot rebuild failed",
            )
            failed = client.get("/api/v1/healthbeat/ready")
            self.assertEqual(failed.status_code, 503)
            self.assertIn("snapshot rebuild failed", " ".join(failed.json()["failures"]))
        finally:
            if previous is None:
                os.environ.pop("HEALTH_RECEIVER_WORKERS_EXTERNAL", None)
            else:
                os.environ["HEALTH_RECEIVER_WORKERS_EXTERNAL"] = previous

    def test_agent_api_is_local_tokenless_and_returns_documented_context(self) -> None:
        self.ingest_quantities(
            [
                {
                    "uuid": "agent-steps",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "value": 4321,
                    "unit": "count",
                    "start_date": "2026-08-27T02:00:00Z",
                    "end_date": "2026-08-27T02:01:00Z",
                    "source_name": "My Apple Watch",
                },
                {
                    "uuid": "agent-hrv",
                    "type": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                    "value": 48,
                    "unit": "ms",
                    "start_date": "2026-08-27T02:00:00Z",
                    "end_date": "2026-08-27T02:00:01Z",
                    "source_name": "My Apple Watch",
                },
            ]
        )
        self.ingest_sleep(
            [
                {
                    "uuid": "agent-sleep",
                    "type": "HKCategoryTypeIdentifierSleepAnalysis",
                    "value": 3,
                    "value_label": "Asleep Core",
                    "start_date": "2026-08-26T15:00:00Z",
                    "end_date": "2026-08-26T22:00:00Z",
                    "source_name": "My Apple Watch",
                }
            ]
        )
        normalize_day(self.database, date(2026, 8, 27))

        catalog = self.client.get("/api/v1/agent/catalog")
        self.assertEqual(catalog.status_code, 200)
        self.assertEqual(catalog.json()["access"], "localhost-only; no token")
        self.assertIn("steps", catalog.json()["metrics"])
        self.assertIn("heart_rate_zones", catalog.json()["workout_fields"])

        context = self.client.get("/api/v1/agent/context/2026-08-27")
        self.assertEqual(context.status_code, 200, context.text)
        payload = context.json()
        self.assertEqual(payload["activity"]["steps"], 4321)
        self.assertEqual(payload["sleep"]["main_sleep_minutes"], 420)
        self.assertNotIn("segments_json", payload["sleep"])
        self.assertIn("days_28", payload["trends"])
        self.assertEqual(payload["data_quality"]["metric_status"]["hrv_sdnn_ms"]["status"], "available")

        series = self.client.get(
            "/api/v1/agent/series/steps?from_date=2026-08-27&to_date=2026-08-27"
        )
        self.assertEqual(series.status_code, 200)
        self.assertEqual(series.json()["points"][0]["value"], 4321)
        self.assertEqual(series.json()["definition"]["unit"], "count")

        tailscale = TestClient(
            self.app,
            base_url="https://receiver.example.ts.net",
            client=("127.0.0.1", 50005),
        )
        self.assertEqual(tailscale.get("/api/v1/agent/catalog").status_code, 403)

        lan = TestClient(
            self.app,
            base_url="http://10.0.0.5:8787",
            client=("10.0.0.20", 50006),
        )
        self.assertEqual(lan.get("/api/v1/agent/catalog").status_code, 403)

    def test_agent_series_rejects_unknown_and_oversized_ranges(self) -> None:
        self.assertEqual(self.client.get("/api/v1/agent/series/not-a-metric").status_code, 404)
        response = self.client.get(
            "/api/v1/agent/series/steps?from_date=2025-01-01&to_date=2026-08-27"
        )
        self.assertEqual(response.status_code, 400)

    def test_readiness_is_deep_and_local_only(self) -> None:
        response = self.client.get("/api/v1/healthbeat/ready")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ready")
        self.assertEqual(response.json()["database"], "ok")
        self.assertIn("normalization_worker_heartbeat_age_seconds", response.json())

        lan = TestClient(
            self.app,
            base_url="http://10.0.0.5:8787",
            client=("10.0.0.20", 50007),
        )
        self.assertEqual(lan.get("/api/v1/healthbeat/ready").status_code, 403)


if __name__ == "__main__":
    unittest.main()
