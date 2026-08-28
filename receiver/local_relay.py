from __future__ import annotations

import json
import os
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .settings import AppPaths
from .sync_crypto import EnvelopeError, peek_header
from .v2_ingestion import BatchIngestionService, IngestionError


MAX_ENVELOPE_BYTES = 16 * 1024 * 1024
MAX_PACK_BYTES = 64 * 1024 * 1024
MAX_PACK_ENVELOPES = 128
PACK_FORMAT = "health-relay-pack/1"


@dataclass(frozen=True)
class ConsumeResult:
    discovered: int = 0
    committed: int = 0
    duplicates: int = 0
    quarantined: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "discovered": self.discovered,
            "committed": self.committed,
            "duplicates": self.duplicates,
            "quarantined": self.quarantined,
        }


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _safe_component(value: Any) -> str:
    rendered = str(value)
    if not rendered or rendered in {".", ".."} or any(char in rendered for char in "/\\\0"):
        raise EnvelopeError("unsafe routing identifier")
    return rendered


class LocalRelayConsumer:
    """Consume immutable encrypted objects from a filesystem-backed relay.

    This adapter mirrors the lifecycle used by S3: inbox objects are immutable,
    receipts are written independently, and processed/quarantine retain evidence.
    """

    def __init__(self, paths: AppPaths, ingestion: BatchIngestionService) -> None:
        self.paths = paths
        self.ingestion = ingestion
        self.paths.ensure()

    def consume_once(self, limit: int = 100) -> ConsumeResult:
        if limit < 1:
            raise ValueError("limit must be at least 1")
        files = sorted(
            path
            for path in self.paths.inbox.rglob("*")
            if path.is_file() and path.suffix in {".henv", ".hpack"}
        )[:limit]
        committed = duplicates = quarantined = 0
        for path in files:
            try:
                file_committed, file_duplicates = self._consume_file(path)
                committed += file_committed
                duplicates += file_duplicates
            except (EnvelopeError, IngestionError, OSError, ValueError, json.JSONDecodeError) as exc:
                self._quarantine(path, exc)
                quarantined += 1
        return ConsumeResult(len(files), committed, duplicates, quarantined)

    def _consume_file(self, path: Path) -> tuple[int, int]:
        maximum_size = MAX_PACK_BYTES if path.suffix == ".hpack" else MAX_ENVELOPE_BYTES
        if path.stat().st_size > maximum_size:
            if path.suffix == ".hpack":
                raise IngestionError("encrypted relay pack exceeds the 64 MiB limit")
            raise IngestionError("encrypted envelope exceeds the 16 MiB limit")
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise IngestionError("relay object must be a JSON object")
        if path.suffix == ".hpack":
            return self._consume_pack(path, payload)
        duplicate, device_id, batch_id, sequence = self._consume_envelope(
            payload,
            path.relative_to(self.paths.inbox).as_posix(),
        )
        destination = self.paths.processed / device_id / f"{sequence:020d}-{batch_id}.henv"
        self._move_processed(path, destination)
        return int(not duplicate), int(duplicate)

    def _consume_envelope(
        self,
        envelope: dict[str, Any],
        object_key: str,
    ) -> tuple[bool, str, str, int]:
        if not isinstance(envelope, dict):
            raise IngestionError("encrypted envelope must be a JSON object")
        header = peek_header(envelope)
        device_id = _safe_component(header["device_id"])
        batch_id = _safe_component(header["batch_id"])
        sequence = int(header["sequence"])
        receipt = self.ingestion.ingest(envelope, object_key=object_key)
        receipt_path = self.paths.receipts / device_id / f"{sequence:020d}-{batch_id}.json"
        _atomic_json(receipt_path, receipt)
        return bool(receipt.get("duplicate")), device_id, batch_id, sequence

    def _consume_pack(self, path: Path, pack: dict[str, Any]) -> tuple[int, int]:
        if pack.get("protocol") != PACK_FORMAT:
            raise IngestionError("unsupported relay pack protocol")
        pack_id = _safe_component(pack.get("pack_id"))
        device_id = _safe_component(pack.get("device_id"))
        envelopes = pack.get("envelopes")
        if not isinstance(envelopes, list) or not 1 <= len(envelopes) <= MAX_PACK_ENVELOPES:
            raise IngestionError("relay pack must contain 1 to 128 envelopes")

        headers = []
        for envelope in envelopes:
            if not isinstance(envelope, dict):
                raise IngestionError("relay pack envelope must be a JSON object")
            header = peek_header(envelope)
            if _safe_component(header["device_id"]) != device_id:
                raise IngestionError("relay pack contains an envelope for another device")
            headers.append(header)
        sequences = [int(header["sequence"]) for header in headers]
        if sequences != sorted(sequences) or len(sequences) != len(set(sequences)):
            raise IngestionError("relay pack sequences must be unique and ordered")
        if pack.get("first_sequence") != sequences[0] or pack.get("last_sequence") != sequences[-1]:
            raise IngestionError("relay pack sequence range does not match its envelopes")

        relative = path.relative_to(self.paths.inbox).as_posix()
        committed = duplicates = 0
        for envelope, header in zip(envelopes, headers, strict=True):
            batch_id = _safe_component(header["batch_id"])
            sequence = int(header["sequence"])
            duplicate, _, _, _ = self._consume_envelope(
                envelope,
                f"{relative}#{sequence:020d}-{batch_id}",
            )
            committed += int(not duplicate)
            duplicates += int(duplicate)

        destination = self.paths.processed / device_id / (
            f"{sequences[0]:020d}-{sequences[-1]:020d}-{pack_id}.hpack"
        )
        self._move_processed(path, destination)
        return committed, duplicates

    @staticmethod
    def _move_processed(path: Path, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            path.unlink()
        else:
            shutil.move(path, destination)

    def _quarantine(self, path: Path, error: Exception) -> None:
        relative = path.relative_to(self.paths.inbox)
        destination = self.paths.quarantine / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            destination = destination.with_name(f"{destination.stem}.duplicate{destination.suffix}")
        shutil.move(path, destination)
        _atomic_json(
            destination.with_suffix(destination.suffix + ".error.json"),
            {
                "object_key": relative.as_posix(),
                "error_type": type(error).__name__,
                "error": str(error),
            },
        )
