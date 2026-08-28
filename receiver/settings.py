from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path


def default_data_root() -> Path:
    override = os.environ.get("HEALTH_TRACKER_HOME")
    if override:
        return Path(override).expanduser().resolve()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "HealthTracker"
    xdg = os.environ.get("XDG_DATA_HOME")
    return (Path(xdg).expanduser() if xdg else Path.home() / ".local" / "share") / "health-tracker"


@dataclass(frozen=True)
class AppPaths:
    root: Path

    @classmethod
    def default(cls) -> "AppPaths":
        return cls(default_data_root())

    @property
    def database(self) -> Path:
        return self.root / "health.sqlite3"

    @property
    def keys(self) -> Path:
        return self.root / "keys"

    @property
    def relay(self) -> Path:
        return self.root / "relay"

    @property
    def inbox(self) -> Path:
        return self.relay / "inbox"

    @property
    def processed(self) -> Path:
        return self.relay / "processed"

    @property
    def receipts(self) -> Path:
        return self.relay / "receipts"

    @property
    def quarantine(self) -> Path:
        return self.relay / "quarantine"

    def ensure(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        for directory in (
            self.keys,
            self.inbox,
            self.processed,
            self.receipts,
            self.quarantine,
        ):
            directory.mkdir(parents=True, exist_ok=True)
