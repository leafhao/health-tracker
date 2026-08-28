from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path

from .database import Database
from .settings import AppPaths


def configured_retention_days() -> int:
    raw = os.environ.get("HEALTH_RELAY_RETENTION_DAYS", "14")
    try:
        days = int(raw)
    except ValueError as exc:
        raise ValueError("HEALTH_RELAY_RETENTION_DAYS must be an integer") from exc
    if not 1 <= days <= 365:
        raise ValueError("relay retention must be between 1 and 365 days")
    return days


@dataclass(frozen=True)
class RetentionResult:
    confirmed_envelopes_deleted: int = 0
    receipt_files_deleted: int = 0
    unconfirmed_preserved: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "confirmed_envelopes_deleted": self.confirmed_envelopes_deleted,
            "receipt_files_deleted": self.receipt_files_deleted,
            "unconfirmed_preserved": self.unconfirmed_preserved,
        }


class LocalRelayRetention:
    """Apply bounded retention without ever deleting an unconfirmed envelope."""

    def __init__(self, paths: AppPaths, database: Database) -> None:
        self.paths = paths
        self.database = database

    def cleanup(self, retention_days: int | None = None, now: float | None = None) -> RetentionResult:
        days = retention_days if retention_days is not None else configured_retention_days()
        if not 1 <= days <= 365:
            raise ValueError("retention_days must be between 1 and 365")
        current = now if now is not None else time.time()
        envelope_cutoff = current - days * 86_400
        receipt_cutoff = current - max(30, days * 2) * 86_400
        deleted = receipt_deleted = preserved = 0

        for envelope in self.paths.processed.rglob("*.henv"):
            if not envelope.is_file() or envelope.stat().st_mtime >= envelope_cutoff:
                continue
            relative = envelope.relative_to(self.paths.processed)
            receipt = (self.paths.receipts / relative).with_suffix(".json")
            if not receipt.exists():
                preserved += 1
                continue
            envelope.unlink()
            deleted += 1

        for receipt in self.paths.receipts.rglob("*.json"):
            if not receipt.is_file() or receipt.stat().st_mtime >= receipt_cutoff:
                continue
            filename = receipt.stem
            batch_id = filename.split("-", 1)[1] if "-" in filename else ""
            exists = self.database.fetch_all(
                "SELECT 1 AS found FROM sync_receipts WHERE batch_id = ? LIMIT 1", (batch_id,)
            )
            if exists:
                receipt.unlink()
                receipt_deleted += 1
        return RetentionResult(deleted, receipt_deleted, preserved)
