from __future__ import annotations

import base64
import gzip
import hashlib
import json
from dataclasses import dataclass
from typing import Any, Mapping

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.hpke import AEAD, KDF, KEM, Suite


FORMAT = "health-envelope/1"
SIGNATURE_PREFIX = b"HEALTH-ENVELOPE-V1\x00"
INFO_PREFIX = b"health-envelope-v1\x00"
SUITE = Suite(KEM.X25519, KDF.HKDF_SHA256, AEAD.CHACHA20_POLY1305)


class EnvelopeError(ValueError):
    pass


@dataclass(frozen=True)
class OpenedEnvelope:
    header: dict[str, Any]
    payload: dict[str, Any]


def _canonical_json(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def _decode_b64(value: Any, field: str) -> bytes:
    if not isinstance(value, str):
        raise EnvelopeError(f"{field} must be base64 text")
    try:
        return base64.b64decode(value, validate=True)
    except Exception as exc:
        raise EnvelopeError(f"invalid {field}") from exc


def _info(header_bytes: bytes) -> bytes:
    return INFO_PREFIX + hashlib.sha256(header_bytes).digest()


def _validate_header(header: Mapping[str, Any]) -> None:
    required = {
        "protocol",
        "batch_id",
        "device_id",
        "sequence",
        "receiver_key_id",
        "signing_key_id",
        "created_at",
        "content_type",
        "content_encoding",
        "plaintext_size",
        "padding_size",
    }
    missing = required - header.keys()
    if missing:
        raise EnvelopeError(f"missing header fields: {', '.join(sorted(missing))}")
    if header["protocol"] != FORMAT:
        raise EnvelopeError("unsupported envelope protocol")
    if header["content_encoding"] not in {"identity", "gzip"}:
        raise EnvelopeError("unsupported content encoding")
    if not isinstance(header["sequence"], int) or header["sequence"] < 1:
        raise EnvelopeError("invalid sequence")
    if not isinstance(header["plaintext_size"], int) or header["plaintext_size"] < 0:
        raise EnvelopeError("invalid plaintext size")
    if not isinstance(header["padding_size"], int) or header["padding_size"] < 0:
        raise EnvelopeError("invalid padding size")


def encode_payload(payload: Mapping[str, Any]) -> bytes:
    return _canonical_json(payload)


def peek_header(envelope: Mapping[str, Any]) -> dict[str, Any]:
    """Decode routing fields without trusting them; callers must still verify the signature."""
    if envelope.get("format") != FORMAT:
        raise EnvelopeError("unsupported envelope format")
    header_bytes = _decode_b64(envelope.get("header_base64"), "header_base64")
    if len(header_bytes) > 16_384:
        raise EnvelopeError("envelope header is too large")
    try:
        header = json.loads(header_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EnvelopeError("invalid header JSON") from exc
    if not isinstance(header, dict):
        raise EnvelopeError("header must be an object")
    _validate_header(header)
    return header


def seal_envelope(
    header: Mapping[str, Any],
    payload: Mapping[str, Any],
    receiver_public_key: X25519PublicKey,
    device_signing_key: Ed25519PrivateKey,
) -> dict[str, str]:
    """Seal one batch using RFC 9180 HPKE and bind it to a device signature."""
    header_copy = dict(header)
    _validate_header(header_copy)
    plaintext = encode_payload(payload)
    if header_copy["plaintext_size"] != len(plaintext):
        raise EnvelopeError("plaintext_size does not match encoded payload")
    padding_size = header_copy["padding_size"]
    padded = plaintext + (b"\x00" * padding_size)
    encoded = gzip.compress(padded, mtime=0) if header_copy["content_encoding"] == "gzip" else padded
    header_bytes = _canonical_json(header_copy)
    hpke_ciphertext = SUITE.encrypt(encoded, receiver_public_key, info=_info(header_bytes))
    signature = device_signing_key.sign(
        SIGNATURE_PREFIX + header_bytes + hpke_ciphertext
    )
    return {
        "format": FORMAT,
        "header_base64": _b64(header_bytes),
        "hpke_ciphertext_base64": _b64(hpke_ciphertext),
        "signature_base64": _b64(signature),
    }


def open_envelope(
    envelope: Mapping[str, Any],
    receiver_private_key: X25519PrivateKey,
    device_signing_public_key: Ed25519PublicKey,
) -> OpenedEnvelope:
    """Verify, decrypt and decode one envelope; never returns unauthenticated data."""
    if envelope.get("format") != FORMAT:
        raise EnvelopeError("unsupported envelope format")
    header_bytes = _decode_b64(envelope.get("header_base64"), "header_base64")
    hpke_ciphertext = _decode_b64(
        envelope.get("hpke_ciphertext_base64"), "hpke_ciphertext_base64"
    )
    signature = _decode_b64(envelope.get("signature_base64"), "signature_base64")
    try:
        device_signing_public_key.verify(
            signature, SIGNATURE_PREFIX + header_bytes + hpke_ciphertext
        )
    except InvalidSignature as exc:
        raise EnvelopeError("invalid device signature") from exc
    try:
        header = json.loads(header_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EnvelopeError("invalid header JSON") from exc
    if not isinstance(header, dict):
        raise EnvelopeError("header must be an object")
    _validate_header(header)
    try:
        encoded = SUITE.decrypt(
            hpke_ciphertext, receiver_private_key, info=_info(header_bytes)
        )
    except Exception as exc:
        raise EnvelopeError("HPKE decryption failed") from exc
    if header["content_encoding"] == "gzip":
        try:
            padded = gzip.decompress(encoded)
        except (OSError, EOFError) as exc:
            raise EnvelopeError("invalid gzip payload") from exc
    else:
        padded = encoded
    padding_size = header["padding_size"]
    if padding_size > len(padded) or (padding_size and padded[-padding_size:] != b"\x00" * padding_size):
        raise EnvelopeError("invalid envelope padding")
    plaintext = padded[:-padding_size] if padding_size else padded
    if len(plaintext) != header["plaintext_size"]:
        raise EnvelopeError("plaintext size mismatch")
    try:
        payload = json.loads(plaintext)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EnvelopeError("invalid payload JSON") from exc
    if not isinstance(payload, dict):
        raise EnvelopeError("payload must be an object")
    return OpenedEnvelope(header=header, payload=payload)
