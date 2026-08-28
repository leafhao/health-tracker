from __future__ import annotations

import hashlib
import os
import tempfile
import unittest
from pathlib import Path

from fastapi.testclient import TestClient

from receiver.app import create_app


TOKEN = "test-only-token"


class ReceiverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        os.environ["HEALTH_RECEIVER_TOKEN_SHA256"] = hashlib.sha256(TOKEN.encode()).hexdigest()
        self.app = create_app(Path(self.tempdir.name) / "test.sqlite3")
        self.client = TestClient(self.app)
        self.headers = {"Authorization": f"Bearer {TOKEN}"}

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_health_is_public(self) -> None:
        response = self.client.get("/api/v1/healthbeat/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ok")

    def test_ingest_requires_token(self) -> None:
        response = self.client.post("/api/v1/healthbeat/quantity-samples", json={"records": []})
        self.assertEqual(response.status_code, 401)

    def test_quantity_upsert_is_idempotent(self) -> None:
        record = {
            "uuid": "quantity-1",
            "type": "HKQuantityTypeIdentifierHeartRate",
            "value": 65,
            "unit": "count/min",
            "start_date": "2026-08-27 04:00:00.000",
            "end_date": "2026-08-27 04:01:00.000",
        }
        first = self.client.post(
            "/api/v1/healthbeat/quantity-samples", json={"records": [record]}, headers=self.headers
        )
        record["value"] = 67
        second = self.client.post(
            "/api/v1/healthbeat/quantity-samples", json={"records": [record]}, headers=self.headers
        )
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertEqual(self.app.state.database.count("quantity_samples"), 1)
        stored = self.app.state.database.fetch_all("SELECT value FROM quantity_samples")[0]
        self.assertEqual(stored["value"], 67)

    def test_day_export_includes_cross_day_sleep_and_target_day_workout(self) -> None:
        sleep = {
            "uuid": "sleep-1",
            "type": "HKCategoryTypeIdentifierSleepAnalysis",
            "value": 3,
            "value_label": "asleepCore",
            "start_date": "2026-08-26T15:00:00Z",
            "end_date": "2026-08-27T00:00:00Z",
        }
        workout = {
            "uuid": "workout-1",
            "activity_type": "running",
            "duration_seconds": 1800,
            "start_date": "2026-08-27T10:00:00Z",
            "end_date": "2026-08-27T10:30:00Z",
        }
        self.client.post("/api/v1/healthbeat/category-samples", json={"records": [sleep]}, headers=self.headers)
        self.client.post("/api/v1/healthbeat/workouts", json={"records": [workout]}, headers=self.headers)

        response = self.client.get("/api/v1/days/2026-08-27", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual([item["uuid"] for item in payload["sleep_samples"]], ["sleep-1"])
        self.assertEqual([item["uuid"] for item in payload["workouts"]], ["workout-1"])

    def test_day_sleep_window_includes_nap_but_excludes_next_night(self) -> None:
        records = [
            {
                "uuid": "target-day-nap",
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "value": 3,
                "start_date": "2026-08-27T05:00:00Z",
                "end_date": "2026-08-27T05:30:00Z",
            },
            {
                "uuid": "next-night-sleep",
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "value": 3,
                "start_date": "2026-08-27T15:00:00Z",
                "end_date": "2026-08-27T23:00:00Z",
            },
        ]
        self.client.post(
            "/api/v1/healthbeat/category-samples", json={"records": records}, headers=self.headers
        )

        response = self.client.get("/api/v1/days/2026-08-27", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            [item["uuid"] for item in response.json()["sleep_samples"]],
            ["target-day-nap"],
        )

    def test_reconcile_deletes_only_stale_uuid_in_slice(self) -> None:
        records = [
            {
                "uuid": uuid,
                "type": "HKQuantityTypeIdentifierHeartRate",
                "value": 60,
                "start_date": f"2026-08-27T0{hour}:00:00Z",
                "end_date": f"2026-08-27T0{hour}:01:00Z",
            }
            for uuid, hour in (("keep", 1), ("delete", 2))
        ]
        self.client.post("/api/v1/healthbeat/quantity-samples", json={"records": records}, headers=self.headers)
        response = self.client.post(
            "/api/v1/healthbeat/reconcile",
            json={
                "table": "health_quantity_samples",
                "type_column": "type",
                "type_value": "HKQuantityTypeIdentifierHeartRate",
                "since": "2026-08-27T00:00:00Z",
                "until": "2026-08-28T00:00:00Z",
                "valid_uuids": ["keep"],
            },
            headers=self.headers,
        )
        self.assertEqual(response.json(), {"deleted": 1})
        self.assertEqual(self.app.state.database.count("quantity_samples"), 1)


if __name__ == "__main__":
    unittest.main()
