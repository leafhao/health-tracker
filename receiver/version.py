from __future__ import annotations

import os
import subprocess
from pathlib import Path


RUNTIME_ROOT = Path(__file__).resolve().parent.parent


def _read_optional(path: Path) -> str | None:
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value or None


def _product_version() -> str:
    return (
        os.environ.get("HEALTH_TRACKER_VERSION")
        or _read_optional(RUNTIME_ROOT / "VERSION")
        or "0.0.0+unknown"
    )


def _git_commit() -> str:
    configured = os.environ.get("HEALTH_TRACKER_GIT_COMMIT")
    if configured:
        return configured
    recorded = _read_optional(RUNTIME_ROOT / "RELEASE_COMMIT")
    if recorded:
        return recorded
    try:
        return subprocess.run(
            ["git", "-C", str(RUNTIME_ROOT), "rev-parse", "--short=12", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


PRODUCT_VERSION = _product_version()
GIT_COMMIT = _git_commit()


def version_payload() -> dict[str, str]:
    return {"product_version": PRODUCT_VERSION, "git_commit": GIT_COMMIT}
