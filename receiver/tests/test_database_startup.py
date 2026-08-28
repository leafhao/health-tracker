from __future__ import annotations

import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class ConcurrentDatabaseStartupTests(unittest.TestCase):
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
            self.assertEqual(count, 11)

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
