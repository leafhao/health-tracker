from __future__ import annotations

import copy
import base64
import json
import unittest
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from receiver.sync_crypto import EnvelopeError, encode_payload, open_envelope, seal_envelope


class SyncCryptoTests(unittest.TestCase):
    def setUp(self) -> None:
        self.receiver_key = X25519PrivateKey.generate()
        self.signing_key = Ed25519PrivateKey.generate()
        self.payload = {
            "schema_version": 1,
            "batch_id": "0198d8e0-test-batch",
            "owner_id": "owner-test",
            "device_id": "device-test",
            "stream_id": "HKQuantityTypeIdentifierHeartRate",
            "sequence": 42,
            "created_at": "2026-08-28T14:00:00.000Z",
            "events": [
                {
                    "event_id": "event-0000000001",
                    "operation": "upsert",
                    "entity_type": "quantity",
                    "source_uuid": "sample-uuid",
                    "observed_at": "2026-08-28T13:59:00.000Z",
                    "payload": {"value": 72.0, "unit": "count/min"},
                }
            ],
        }

    def header(self, encoding: str, padding: int) -> dict:
        return {
            "protocol": "health-envelope/1",
            "batch_id": self.payload["batch_id"],
            "device_id": self.payload["device_id"],
            "sequence": self.payload["sequence"],
            "receiver_key_id": "receiver-test",
            "signing_key_id": "iphone-test",
            "created_at": self.payload["created_at"],
            "content_type": "application/vnd.health-event-batch+json;v=1",
            "content_encoding": encoding,
            "plaintext_size": len(encode_payload(self.payload)),
            "padding_size": padding,
        }

    def test_round_trip_identity_and_gzip(self) -> None:
        for encoding in ("identity", "gzip"):
            with self.subTest(encoding=encoding):
                envelope = seal_envelope(
                    self.header(encoding, 32),
                    self.payload,
                    self.receiver_key.public_key(),
                    self.signing_key,
                )
                opened = open_envelope(
                    envelope, self.receiver_key, self.signing_key.public_key()
                )
                self.assertEqual(opened.payload, self.payload)
                self.assertEqual(opened.header["sequence"], 42)

    def test_tampering_is_rejected_before_decryption(self) -> None:
        envelope = seal_envelope(
            self.header("identity", 0),
            self.payload,
            self.receiver_key.public_key(),
            self.signing_key,
        )
        tampered = copy.deepcopy(envelope)
        value = bytearray(__import__("base64").b64decode(tampered["hpke_ciphertext_base64"]))
        value[-1] ^= 1
        tampered["hpke_ciphertext_base64"] = __import__("base64").b64encode(value).decode()
        with self.assertRaisesRegex(EnvelopeError, "signature"):
            open_envelope(tampered, self.receiver_key, self.signing_key.public_key())

    def test_wrong_device_key_is_rejected(self) -> None:
        envelope = seal_envelope(
            self.header("identity", 0),
            self.payload,
            self.receiver_key.public_key(),
            self.signing_key,
        )
        with self.assertRaisesRegex(EnvelopeError, "signature"):
            open_envelope(
                envelope,
                self.receiver_key,
                Ed25519PrivateKey.generate().public_key(),
            )

    def test_opens_swift_cryptokit_hpke_fixture(self) -> None:
        fixture_path = Path(__file__).with_name("fixtures") / "swift-hpke-envelope-v1.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        receiver_key = X25519PrivateKey.from_private_bytes(
            base64.b64decode(fixture["receiver_private_key_base64"])
        )
        signing_key = Ed25519PublicKey.from_public_bytes(
            base64.b64decode(fixture["device_signing_public_key_base64"])
        )
        opened = open_envelope(fixture["envelope"], receiver_key, signing_key)
        self.assertEqual(opened.payload, fixture["expected_payload"])


if __name__ == "__main__":
    unittest.main()
