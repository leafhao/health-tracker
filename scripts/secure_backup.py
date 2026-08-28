#!/usr/bin/env python3
"""Streaming encryption for portable HealthTracker backups.

The encrypted file format is intentionally small and self-contained:
MAGIC || 12-byte nonce || AES-256-GCM ciphertext || 16-byte tag.
The key is stored separately and must be copied to a password manager or other
recovery location before encrypted backups are moved off the Mac.
"""

from __future__ import annotations

import argparse
import base64
import os
import secrets
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


MAGIC = b"HTBK1\x00"
NONCE_SIZE = 12
TAG_SIZE = 16
CHUNK_SIZE = 1024 * 1024


def load_key(path: Path) -> bytes:
    raw = path.expanduser().resolve().read_bytes()
    if len(raw) != 32:
        raise ValueError("backup encryption key must contain exactly 32 bytes")
    return raw


def initialize_key(path: Path) -> tuple[Path, str, bool]:
    target = path.expanduser().resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        key = load_key(target)
        return target, base64.urlsafe_b64encode(key).decode("ascii"), False
    key = secrets.token_bytes(32)
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(key)
        output.flush()
        os.fsync(output.fileno())
    return target, base64.urlsafe_b64encode(key).decode("ascii"), True


def encrypt_file(source: Path, destination: Path, key_path: Path) -> Path:
    source = source.expanduser().resolve()
    destination = destination.expanduser().resolve()
    key = load_key(key_path)
    nonce = secrets.token_bytes(NONCE_SIZE)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp-{os.getpid()}")
    encryptor = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
    encryptor.authenticate_additional_data(MAGIC)
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with source.open("rb") as input_file, os.fdopen(descriptor, "wb") as output_file:
            output_file.write(MAGIC)
            output_file.write(nonce)
            while chunk := input_file.read(CHUNK_SIZE):
                output_file.write(encryptor.update(chunk))
            output_file.write(encryptor.finalize())
            output_file.write(encryptor.tag)
            output_file.flush()
            os.fsync(output_file.fileno())
        temporary.replace(destination)
        destination.chmod(0o600)
        return destination
    finally:
        temporary.unlink(missing_ok=True)


def _decrypt_stream(source: Path, key_path: Path, destination: Path | None) -> None:
    source = source.expanduser().resolve()
    key = load_key(key_path)
    size = source.stat().st_size
    minimum = len(MAGIC) + NONCE_SIZE + TAG_SIZE
    if size < minimum:
        raise ValueError("encrypted backup is truncated")
    with source.open("rb") as input_file:
        if input_file.read(len(MAGIC)) != MAGIC:
            raise ValueError("unsupported encrypted backup format")
        nonce = input_file.read(NONCE_SIZE)
        input_file.seek(-TAG_SIZE, os.SEEK_END)
        tag = input_file.read(TAG_SIZE)
        ciphertext_size = size - len(MAGIC) - NONCE_SIZE - TAG_SIZE
        input_file.seek(len(MAGIC) + NONCE_SIZE)
        decryptor = Cipher(algorithms.AES(key), modes.GCM(nonce, tag)).decryptor()
        decryptor.authenticate_additional_data(MAGIC)

        output_file = None
        temporary = None
        try:
            if destination is not None:
                destination = destination.expanduser().resolve()
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_name(f".{destination.name}.tmp-{os.getpid()}")
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                output_file = os.fdopen(descriptor, "wb")
            remaining = ciphertext_size
            while remaining:
                chunk = input_file.read(min(CHUNK_SIZE, remaining))
                if not chunk:
                    raise ValueError("encrypted backup is truncated")
                remaining -= len(chunk)
                plaintext = decryptor.update(chunk)
                if output_file is not None:
                    output_file.write(plaintext)
            final = decryptor.finalize()
            if output_file is not None:
                output_file.write(final)
                output_file.flush()
                os.fsync(output_file.fileno())
                output_file.close()
                output_file = None
                temporary.replace(destination)
                destination.chmod(0o600)
        finally:
            if output_file is not None:
                output_file.close()
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def decrypt_file(source: Path, destination: Path, key_path: Path) -> Path:
    _decrypt_stream(source, key_path, destination)
    return destination.expanduser().resolve()


def verify_file(source: Path, key_path: Path) -> None:
    _decrypt_stream(source, key_path, None)


def main() -> None:
    parser = argparse.ArgumentParser(description="Encrypt and verify HealthTracker backups")
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init-key")
    init.add_argument("--key", type=Path, required=True)
    encrypt = commands.add_parser("encrypt")
    encrypt.add_argument("--key", type=Path, required=True)
    encrypt.add_argument("--input", type=Path, required=True)
    encrypt.add_argument("--output", type=Path, required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--key", type=Path, required=True)
    verify.add_argument("--input", type=Path, required=True)
    decrypt = commands.add_parser("decrypt")
    decrypt.add_argument("--key", type=Path, required=True)
    decrypt.add_argument("--input", type=Path, required=True)
    decrypt.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.command == "init-key":
        path, recovery, created = initialize_key(args.key)
        print(f"key_path={path}")
        print(f"created={'yes' if created else 'no'}")
        print(f"recovery_key_base64={recovery}")
    elif args.command == "encrypt":
        print(encrypt_file(args.input, args.output, args.key))
    elif args.command == "verify":
        verify_file(args.input, args.key)
        print("ok")
    elif args.command == "decrypt":
        print(decrypt_file(args.input, args.output, args.key))


if __name__ == "__main__":
    main()
