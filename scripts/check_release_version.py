#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def values(pattern: str, text: str) -> set[str]:
    return {match.strip('"') for match in re.findall(pattern, text)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify product release version consistency")
    parser.add_argument("--tag", help="Expected Git tag, for example v0.1.0-beta.1")
    args = parser.parse_args()

    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if not SEMVER.fullmatch(version):
        raise SystemExit(f"VERSION is not valid SemVer: {version!r}")
    bundle_version = version.split("-", 1)[0].split("+", 1)[0]

    project = (ROOT / "ios/HealthBeat/Health Beat.xcodeproj/project.pbxproj").read_text(
        encoding="utf-8"
    )
    product_values = values(r"HEALTH_TRACKER_PRODUCT_VERSION = ([^;]+);", project)
    if product_values != {version}:
        raise SystemExit(
            f"iOS HEALTH_TRACKER_PRODUCT_VERSION values {sorted(product_values)} != {version}"
        )
    marketing_values = values(r"MARKETING_VERSION = ([^;]+);", project)
    if marketing_values != {bundle_version}:
        raise SystemExit(
            f"iOS MARKETING_VERSION values {sorted(marketing_values)} != {bundle_version}"
        )

    openapi = (ROOT / "receiver/openapi.yaml").read_text(encoding="utf-8")
    if f"  version: {version}\n" not in openapi:
        raise SystemExit("receiver/openapi.yaml does not match VERSION")
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    if f"## [{version}]" not in changelog:
        raise SystemExit("CHANGELOG.md has no section for VERSION")
    if args.tag and args.tag != f"v{version}":
        raise SystemExit(f"tag {args.tag!r} does not match v{version}")

    print(f"release version ok: {version} (iOS bundle {bundle_version})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
