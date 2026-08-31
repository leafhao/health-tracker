from __future__ import annotations

import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from receiver.database import Database


class ConcurrentDatabaseStartupTests(unittest.TestCase):
    def test_stale_body_projection_migration_clears_values_and_queues_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            database = Database(Path(tempdir) / "health.sqlite3")
            with database.connection() as connection:
                connection.execute(
                    """INSERT INTO normalized_daily_summaries(
                           timezone, date, body_mass_kg, body_mass_at,
                           body_mass_index, body_mass_index_at,
                           body_mass_index_source, normalized_at
                       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        "Asia/Shanghai", "2026-08-01", 60.0,
                        "2022-08-01T02:00:00.000Z", 21.5,
                        "2022-08-01T02:00:00.000Z", "calculated",
                        "2026-08-31T00:00:00.000Z",
                    ),
                )
                connection.execute(
                    """INSERT INTO normalization_runs(
                           timezone, date, raw_quantity_count, raw_sleep_count,
                           raw_workout_count, normalized_at
                       ) VALUES (?, ?, 1, 0, 0, ?)""",
                    ("Asia/Shanghai", "2026-08-01", "2026-08-31T00:00:00.000Z"),
                )
                connection.execute(
                    """INSERT INTO dashboard_day_snapshots(
                           timezone, date, payload_json, source_normalized_at,
                           materialized_at
                       ) VALUES (?, ?, '{}', ?, ?)""",
                    (
                        "Asia/Shanghai", "2026-08-01",
                        "2026-08-31T00:00:00.000Z", "2026-08-31T00:00:00.000Z",
                    ),
                )
                connection.executescript(
                    (Path(__file__).parents[1] / "migrations" / "0014_expire_stale_body_composition.sql")
                    .read_text(encoding="utf-8")
                )
                daily = connection.execute(
                    """SELECT body_mass_kg, body_mass_at, body_mass_index,
                              body_mass_index_source
                       FROM normalized_daily_summaries
                       WHERE timezone=? AND date=?""",
                    ("Asia/Shanghai", "2026-08-01"),
                ).fetchone()
                queued = connection.execute(
                    """SELECT reason FROM dashboard_snapshot_jobs
                       WHERE timezone=? AND date=?""",
                    ("Asia/Shanghai", "2026-08-01"),
                ).fetchone()
            self.assertEqual(tuple(daily), (None, None, None, None))
            self.assertEqual(queued[0], "expire stale body composition projection")

    def test_multiple_service_processes_can_initialize_the_same_database(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            database = Path(tempdir) / "health.sqlite3"
            code = (
                "import sys; "
                "from receiver.database import Database; "
                "Database(sys.argv[1])"
            )
            processes = [
                subprocess.Popen(
                    [sys.executable, "-c", code, str(database)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for _ in range(6)
            ]
            failures: list[str] = []
            for process in processes:
                stdout, stderr = process.communicate(timeout=20)
                if process.returncode != 0:
                    failures.append(f"stdout={stdout}\nstderr={stderr}")
            self.assertEqual(failures, [])
            with sqlite3.connect(database) as connection:
                count = connection.execute(
                    "SELECT COUNT(*) FROM schema_migrations"
                ).fetchone()[0]
            self.assertEqual(count, 14)

    def test_multiple_service_processes_create_one_receiver_identity(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            code = (
                "import sys; "
                "from receiver.database import Database; "
                "from receiver.identity import load_or_create_identity; "
                "from receiver.settings import AppPaths; "
                "p=AppPaths(__import__('pathlib').Path(sys.argv[1])); p.ensure(); "
                "print(load_or_create_identity(p, Database(p.database)).key_id)"
            )
            processes = [
                subprocess.Popen(
                    [sys.executable, "-c", code, tempdir],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for _ in range(6)
            ]
            key_ids: list[str] = []
            failures: list[str] = []
            for process in processes:
                stdout, stderr = process.communicate(timeout=20)
                if process.returncode != 0:
                    failures.append(f"stdout={stdout}\nstderr={stderr}")
                else:
                    key_ids.append(stdout.strip())
            self.assertEqual(failures, [])
            self.assertEqual(len(set(key_ids)), 1)
            with sqlite3.connect(Path(tempdir) / "health.sqlite3") as connection:
                active = connection.execute(
                    "SELECT COUNT(*) FROM receiver_keys WHERE is_active=1"
                ).fetchone()[0]
            self.assertEqual(active, 1)
            self.assertEqual(len(list((Path(tempdir) / "keys").glob("receiver-*.json"))), 1)
