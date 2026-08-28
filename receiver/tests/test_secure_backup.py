from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from secure_backup import decrypt_file, encrypt_file, initialize_key, verify_file  # noqa: E402


class SecureBackupTests(unittest.TestCase):
    def test_streaming_backup_round_trip_and_tamper_detection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = root / "backup.key"
            source = root / "portable.zip"
            encrypted = root / "portable.htbk"
            restored = root / "restored.zip"
            source.write_bytes(os.urandom(2 * 1024 * 1024 + 137))

            path, recovery, created = initialize_key(key)
            self.assertEqual(path, key.resolve())
            self.assertTrue(created)
            self.assertTrue(recovery)
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)

            encrypt_file(source, encrypted, key)
            verify_file(encrypted, key)
            decrypt_file(encrypted, restored, key)
            self.assertEqual(restored.read_bytes(), source.read_bytes())

            tampered = bytearray(encrypted.read_bytes())
            tampered[len(tampered) // 2] ^= 1
            encrypted.write_bytes(tampered)
            with self.assertRaises(Exception):
                verify_file(encrypted, key)

    def test_existing_key_is_reused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "backup.key"
            _, first_recovery, first_created = initialize_key(key)
            _, second_recovery, second_created = initialize_key(key)
            self.assertTrue(first_created)
            self.assertFalse(second_created)
            self.assertEqual(first_recovery, second_recovery)
