from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
import tempfile
import time
import unittest
from datetime import timedelta
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from fastapi.testclient import TestClient

from receiver.app import create_app
from receiver.cli import _backup_state, _restore_state
from receiver.cloud_relay import CloudBootstrapStore, CloudRelayWorker, receipt_material
from receiver.database import Database
from receiver.identity import load_or_create_identity, register_device
from receiver.local_relay import LocalRelayConsumer
from receiver.normalization_worker import NormalizationWorker
from receiver.retention import LocalRelayRetention
from receiver.settings import AppPaths
from receiver.sync_crypto import encode_payload, seal_envelope
from receiver.v2_ingestion import BatchIngestionService, IngestionError


class V2ReceiverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.paths = AppPaths(Path(self.temporary.name))
        self.database = Database(self.paths.database)
        self.identity = load_or_create_identity(self.paths, self.database)
        self.signing_key = Ed25519PrivateKey.generate()
        public_bytes = self.signing_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        register_device(
            self.database,
            "owner-default",
            "iphone-test-device",
            "Test iPhone",
            "iphone-signing-test",
            base64.b64encode(public_bytes).decode("ascii"),
        )
        self.ingestion = BatchIngestionService(self.database, self.identity)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def envelope(
        self,
        sequence: int = 1,
        batch_id: str = "batch-000000000001",
        events: list[dict] | None = None,
        stream_id: str = "HKQuantityTypeIdentifierHeartRate",
    ) -> dict:
        payload = {
            "schema_version": 1,
            "batch_id": batch_id,
            "previous_batch_id": None if sequence == 1 else "batch-000000000001",
            "owner_id": "owner-default",
            "device_id": "iphone-test-device",
            "stream_id": stream_id,
            "sequence": sequence,
            "created_at": "2026-08-28T03:00:00.000Z",
            "events": events or [
                {
                    "event_id": f"event-{sequence:016d}",
                    "operation": "upsert",
                    "entity_type": "quantity",
                    "source_uuid": f"heart-rate-{sequence}",
                    "observed_at": "2026-08-28T02:59:00.000Z",
                    "payload": {
                        "uuid": f"heart-rate-{sequence}",
                        "type": "HKQuantityTypeIdentifierHeartRate",
                        "value": 72.0,
                        "unit": "count/min",
                        "start_date": "2026-08-28T02:59:00.000Z",
                        "end_date": "2026-08-28T02:59:05.000Z",
                        "source_name": "Apple Watch",
                        "source_bundle_id": "com.apple.health",
                        "device_name": "Apple Watch",
                        "metadata": None,
                    },
                }
            ],
        }
        header = {
            "protocol": "health-envelope/1",
            "batch_id": batch_id,
            "device_id": payload["device_id"],
            "sequence": sequence,
            "receiver_key_id": self.identity.key_id,
            "signing_key_id": "iphone-signing-test",
            "created_at": payload["created_at"],
            "content_type": "application/vnd.health-event-batch+json;v=1",
            "content_encoding": "gzip",
            "plaintext_size": len(encode_payload(payload)),
            "padding_size": 32,
        }
        return seal_envelope(
            header,
            payload,
            self.identity.private_key.public_key(),
            self.signing_key,
        )

    def test_encrypted_device_capabilities_are_upserted_without_normalization_job(self) -> None:
        event = {
            "event_id": "event-capabilities-00000001",
            "operation": "upsert",
            "entity_type": "device_capabilities",
            "source_uuid": "iphone-test-device",
            "observed_at": "2026-08-28T03:00:00.000Z",
            "payload": {
                "device_id": "iphone-test-device",
                "app_version": "1.0",
                "platform_version": "iOS 26.0",
                "health_data_available": True,
                "health_permissions_requested": True,
                "supported_quantity_types_json": json.dumps(
                    ["HKQuantityTypeIdentifierHeartRate"]
                ),
                "supported_domains_json": json.dumps(["sleep", "workout"]),
                "reported_at": "2026-08-28T03:00:00.000Z",
            },
        }
        receipt = self.ingestion.ingest(
            self.envelope(events=[event], stream_id="device-capabilities")
        )
        self.assertEqual(receipt["accepted"], 1)
        report = self.database.fetch_all("SELECT * FROM device_capabilities")[0]
        self.assertEqual(report["device_id"], "iphone-test-device")
        self.assertEqual(report["health_permissions_requested"], 1)
        self.assertEqual(self.database.fetch_all("SELECT * FROM normalization_jobs"), [])

    def cloud_envelope(self, secret: str = "test-secret-never-plaintext") -> dict:
        payload = {
            "protocol": "health-cloud-bootstrap/1",
            "owner_id": "owner-default",
            "device_id": "iphone-test-device",
            "provider": "s3",
            "endpoint": "https://s3.example.test",
            "region": "us-east-1",
            "bucket": "health-test",
            "prefix": "health-tracker",
            "path_style": True,
            "retention_days": 14,
            "access_key": "test-access",
            "secret_key": secret,
            "receipt_hmac_key_base64": base64.b64encode(b"r" * 32).decode("ascii"),
            "configured_at": "2026-08-28T03:00:00.000Z",
            "nonce": "test-nonce",
        }
        encoded = encode_payload(payload)
        header = {
            "protocol": "health-envelope/1",
            "batch_id": "cloud-bootstrap-test",
            "device_id": "iphone-test-device",
            "sequence": 1,
            "receiver_key_id": self.identity.key_id,
            "signing_key_id": "iphone-signing-test",
            "created_at": "2026-08-28T03:00:00.000Z",
            "content_type": "application/vnd.health-cloud-bootstrap+json;v=1",
            "content_encoding": "gzip",
            "plaintext_size": len(encoded),
            "padding_size": 32,
        }
        return seal_envelope(
            header, payload, self.identity.private_key.public_key(), self.signing_key
        )

    def test_encrypted_batch_is_verified_and_idempotently_committed(self) -> None:
        envelope = self.envelope()
        receipt = self.ingestion.ingest(envelope, object_key="phone/device/batch.henv")
        self.assertEqual(receipt["accepted"], 1)
        self.assertFalse(receipt["duplicate"])
        duplicate = self.ingestion.ingest(envelope, object_key="phone/device/batch.henv")
        self.assertTrue(duplicate["duplicate"])
        self.assertEqual(len(self.database.fetch_all("SELECT * FROM raw_events")), 1)
        self.assertEqual(self.database.count("quantity_samples"), 1)
        self.assertEqual(len(self.database.fetch_all("SELECT * FROM normalization_jobs")), 1)
        normalized = NormalizationWorker(self.database).run_once()
        self.assertEqual(normalized.completed, 1)
        job = self.database.fetch_all("SELECT * FROM normalization_jobs")[0]
        self.assertEqual(job["status"], "completed")
        device = self.database.fetch_all("SELECT * FROM devices")[0]
        self.assertEqual(device["last_sequence"], 1)

    def test_repeated_changes_coalesce_to_one_normalization_job_per_day(self) -> None:
        self.ingestion.ingest(self.envelope())
        first = NormalizationWorker(self.database).run_once()
        self.assertEqual(first.completed, 1)

        self.ingestion.ingest(self.envelope(2, "batch-000000000002"))
        jobs = self.database.fetch_all("SELECT * FROM normalization_jobs")
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]["status"], "pending")
        self.assertEqual(jobs[0]["attempts"], 0)

    def test_signature_tampering_does_not_write_any_rows(self) -> None:
        envelope = self.envelope()
        tampered = copy.deepcopy(envelope)
        ciphertext = bytearray(base64.b64decode(tampered["hpke_ciphertext_base64"]))
        ciphertext[-1] ^= 1
        tampered["hpke_ciphertext_base64"] = base64.b64encode(ciphertext).decode("ascii")
        with self.assertRaisesRegex(IngestionError, "signature"):
            self.ingestion.ingest(tampered)
        self.assertEqual(len(self.database.fetch_all("SELECT * FROM ingest_batches")), 0)

    def test_sequence_gap_is_recorded_without_discarding_valid_health_data(self) -> None:
        receipt = self.ingestion.ingest(self.envelope(2, "batch-000000000002"))
        self.assertTrue(receipt["gap_detected"])
        self.assertEqual(self.database.count("quantity_samples"), 1)

    def test_local_relay_writes_receipt_and_quarantines_bad_objects(self) -> None:
        self.paths.ensure()
        good = self.paths.inbox / "iphone-test-device" / "batch.henv"
        good.parent.mkdir(parents=True)
        good.write_text(json.dumps(self.envelope()), encoding="utf-8")
        bad = self.paths.inbox / "broken.henv"
        bad.write_text("not-json", encoding="utf-8")
        result = LocalRelayConsumer(self.paths, self.ingestion).consume_once()
        self.assertEqual(result.as_dict(), {
            "discovered": 2,
            "committed": 1,
            "duplicates": 0,
            "quarantined": 1,
        })
        self.assertEqual(len(list(self.paths.receipts.rglob("*.json"))), 1)
        self.assertEqual(len(list(self.paths.processed.rglob("*.henv"))), 1)
        self.assertEqual(len(list(self.paths.quarantine.rglob("*.henv"))), 1)
        self.assertEqual(len(list(self.paths.quarantine.rglob("*.error.json"))), 1)

    def test_local_relay_unpacks_multiple_envelopes_and_keeps_batch_idempotency(self) -> None:
        self.paths.ensure()
        pack = {
            "protocol": "health-relay-pack/1",
            "pack_id": "pack-test-0001",
            "device_id": "iphone-test-device",
            "created_at": "2026-08-28T03:05:00.000Z",
            "first_sequence": 1,
            "last_sequence": 2,
            "envelopes": [
                self.envelope(1, "batch-000000000001"),
                self.envelope(2, "batch-000000000002"),
            ],
        }
        incoming = self.paths.inbox / "iphone-test-device" / "pack.hpack"
        incoming.parent.mkdir(parents=True)
        incoming.write_text(json.dumps(pack), encoding="utf-8")

        first = LocalRelayConsumer(self.paths, self.ingestion).consume_once()
        self.assertEqual(first.as_dict(), {
            "discovered": 1,
            "committed": 2,
            "duplicates": 0,
            "quarantined": 0,
        })
        self.assertEqual(len(list(self.paths.receipts.rglob("*.json"))), 2)
        self.assertEqual(len(list(self.paths.processed.rglob("*.hpack"))), 1)
        self.assertEqual(self.database.count("quantity_samples"), 2)

        replay = self.paths.inbox / "iphone-test-device" / "pack-replay.hpack"
        replay.write_text(json.dumps(pack), encoding="utf-8")
        second = LocalRelayConsumer(self.paths, self.ingestion).consume_once()
        self.assertEqual(second.committed, 0)
        self.assertEqual(second.duplicates, 2)
        self.assertEqual(self.database.count("quantity_samples"), 2)

    def test_v2_identity_and_direct_ingest_api(self) -> None:
        old_hash = os.environ.get("HEALTH_RECEIVER_TOKEN_SHA256")
        try:
            app = create_app(self.paths.database, self.paths.root)
            client = TestClient(app)
            identity = client.get("/api/v2/system/identity")
            self.assertEqual(identity.status_code, 200)
            self.assertEqual(identity.json()["receiver_key_id"], self.identity.key_id)
            response = client.post("/api/v2/sync/batches", json=self.envelope())
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["status"], "committed")
        finally:
            if old_hash is None:
                os.environ.pop("HEALTH_RECEIVER_TOKEN_SHA256", None)
            else:
                os.environ["HEALTH_RECEIVER_TOKEN_SHA256"] = old_hash

    def test_cloud_bootstrap_is_authenticated_and_only_ciphertext_is_stored(self) -> None:
        secret = "test-secret-never-plaintext"
        app = create_app(self.paths.database, self.paths.root)
        client = TestClient(app)
        response = client.post("/api/v2/cloud/bootstrap", json=self.cloud_envelope(secret))
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["credentials_at_rest"], "encrypted-envelope-only")
        files = list(self.paths.keys.glob("cloud-relay-*.json"))
        self.assertEqual(len(files), 1)
        self.assertNotIn(secret, files[0].read_text(encoding="utf-8"))

    def test_cloud_worker_commits_pack_and_writes_authenticated_receipt(self) -> None:
        CloudBootstrapStore(self.paths, self.ingestion).save(self.cloud_envelope())
        config = CloudBootstrapStore(self.paths, self.ingestion).load_all()[0]
        inbox_key = config.inbox_prefix + "pack-cloud-test.hpack"
        pack = {
            "protocol": "health-relay-pack/1",
            "pack_id": "pack-cloud-test",
            "device_id": "iphone-test-device",
            "created_at": "2026-08-28T03:05:00.000Z",
            "first_sequence": 1,
            "last_sequence": 1,
            "group_id": "incremental",
            "part_number": 1,
            "part_count": 1,
            "envelopes": [self.envelope()],
        }

        class FakeS3:
            def __init__(self):
                self.objects = {inbox_key: json.dumps(pack).encode()}

            def list_objects(self, prefix, max_keys=100):
                return [key for key in self.objects if key.startswith(prefix)][:max_keys]

            def get(self, key):
                return self.objects[key]

            def put(self, key, body, content_type="application/json"):
                self.objects[key] = body

            def delete(self, key):
                self.objects.pop(key, None)

        fake = FakeS3()
        result = CloudRelayWorker(
            self.paths, self.database, self.ingestion, client_factory=lambda _: fake
        ).poll_once()
        self.assertEqual(result.committed_packs, 1)
        self.assertEqual(result.committed_batches, 1)
        receipt_key = config.receipt_prefix + "pack-cloud-test.json"
        receipt = json.loads(fake.objects[receipt_key])
        expected = __import__("hmac").new(
            b"r" * 32, receipt_material(receipt), hashlib.sha256
        ).hexdigest()
        self.assertEqual(receipt["hmac_sha256"], expected)
        self.assertEqual(self.database.count("quantity_samples"), 1)
        self.assertEqual(
            self.database.fetch_all("SELECT status FROM cloud_relay_objects")[0]["status"],
            "committed",
        )

    def test_direct_pack_api_commits_and_replays_idempotently(self) -> None:
        app = create_app(self.paths.database, self.paths.root)
        client = TestClient(app)
        pack = {
            "protocol": "health-relay-pack/1",
            "pack_id": "direct-pack-test-0001",
            "device_id": "iphone-test-device",
            "created_at": "2026-08-28T03:05:00.000Z",
            "first_sequence": 1,
            "last_sequence": 2,
            "group_id": "initial/history",
            "part_number": 1,
            "part_count": 1,
            "envelopes": [
                self.envelope(1, "batch-000000000001"),
                self.envelope(2, "batch-000000000002"),
            ],
        }
        first = client.post("/api/v2/sync/packs", json=pack)
        self.assertEqual(first.status_code, 200, first.text)
        self.assertEqual(first.json()["status"], "committed")
        self.assertEqual(first.json()["committed"], 2)
        self.assertEqual(first.json()["duplicates"], 0)

        replay = client.post("/api/v2/sync/packs", json=pack)
        self.assertEqual(replay.status_code, 200, replay.text)
        self.assertEqual(replay.json()["committed"], 0)
        self.assertEqual(replay.json()["duplicates"], 2)
        self.assertEqual(self.database.count("quantity_samples"), 2)

    def test_pairing_registration_uses_single_use_code_and_rejects_replay(self) -> None:
        app = create_app(self.paths.database, self.paths.root)
        client = TestClient(app)
        pairing = app.state.access_control.create_pairing_session()
        key = Ed25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        body = {
            "owner_id": "ignored-by-server",
            "device_id": "device-second-test",
            "display_name": "Second iPhone",
            "signing_key_id": "iphone-second-test",
            "signing_public_key_base64": base64.b64encode(key).decode("ascii"),
        }
        self.assertEqual(client.post("/api/v2/pairing/devices", json=body).status_code, 401)
        response = client.post(
            "/api/v2/pairing/devices",
            json=body,
            headers={"X-Health-Pairing-Code": pairing["pairing_code"]},
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["device"]["status"], "active")
        self.assertEqual(response.json()["device"]["owner_id"], "owner-default")
        replay = client.post(
            "/api/v2/pairing/devices",
            json=body,
            headers={"X-Health-Pairing-Code": pairing["pairing_code"]},
        )
        self.assertEqual(replay.status_code, 401)

    def test_expired_pairing_code_is_rejected(self) -> None:
        app = create_app(self.paths.database, self.paths.root)
        client = TestClient(app)
        pairing = app.state.access_control.create_pairing_session(lifetime=timedelta(seconds=-1))
        key = Ed25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        response = client.post(
            "/api/v2/pairing/devices",
            json={
                "device_id": "device-expired-test",
                "display_name": "Expired iPhone",
                "signing_key_id": "iphone-expired-test",
                "signing_public_key_base64": base64.b64encode(key).decode("ascii"),
            },
            headers={"X-Health-Pairing-Code": pairing["pairing_code"]},
        )
        self.assertEqual(response.status_code, 401)

    def test_local_pairing_request_waits_for_receiver_approval(self) -> None:
        app = create_app(self.paths.database, self.paths.root)
        client = TestClient(app)
        key = Ed25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        body = {
            "device_id": "device-nearby-test",
            "display_name": "Nearby iPhone",
            "signing_key_id": "iphone-nearby-test",
            "signing_public_key_base64": base64.b64encode(key).decode("ascii"),
        }
        started = client.post("/api/v2/pairing/requests", json=body)
        self.assertEqual(started.status_code, 200, started.text)
        payload = started.json()
        self.assertEqual(payload["status"], "pending")

        status_url = f"/api/v2/pairing/requests/{payload['request_id']}"
        headers = {"X-Health-Pairing-Poll-Token": payload["poll_token"]}
        self.assertEqual(client.get(status_url, headers=headers).json()["status"], "pending")
        approved = app.state.access_control.resolve_local_pairing_request(
            payload["request_id"], approve=True
        )
        self.assertEqual(approved["status"], "approved")
        final = client.get(status_url, headers=headers)
        self.assertEqual(final.status_code, 200, final.text)
        self.assertEqual(final.json()["status"], "approved")
        self.assertEqual(final.json()["receiver"]["receiver_key_id"], self.identity.key_id)

    def test_portable_backup_restores_database_and_same_receiver_key(self) -> None:
        self.ingestion.ingest(self.envelope())
        archive = _backup_state(self.paths, self.database, self.paths.root / "portable.zip")
        restored_paths = AppPaths(self.paths.root / "restored")
        result = _restore_state(archive, restored_paths)
        restored = Database(restored_paths.database)
        self.assertEqual(result["receiver_key_id"], self.identity.key_id)
        self.assertEqual(len(restored.fetch_all("SELECT * FROM raw_events")), 1)
        self.assertEqual(restored.count("quantity_samples"), 1)

    def test_retention_deletes_only_confirmed_old_envelopes(self) -> None:
        self.paths.ensure()
        incoming = self.paths.inbox / "batch.henv"
        incoming.write_text(json.dumps(self.envelope()), encoding="utf-8")
        LocalRelayConsumer(self.paths, self.ingestion).consume_once()
        processed = next(self.paths.processed.rglob("*.henv"))
        receipt = next(self.paths.receipts.rglob("*.json"))
        old = time.time() - 40 * 86_400
        os.utime(processed, (old, old))
        os.utime(receipt, (old, old))
        unconfirmed = self.paths.processed / "unknown" / "old.henv"
        unconfirmed.parent.mkdir(parents=True)
        unconfirmed.write_text("encrypted", encoding="utf-8")
        os.utime(unconfirmed, (old, old))

        result = LocalRelayRetention(self.paths, self.database).cleanup(14)
        self.assertEqual(result.confirmed_envelopes_deleted, 1)
        self.assertEqual(result.receipt_files_deleted, 1)
        self.assertEqual(result.unconfirmed_preserved, 1)
        self.assertTrue(unconfirmed.exists())


if __name__ == "__main__":
    unittest.main()
