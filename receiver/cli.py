from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
import zipfile
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from .database import Database
from .cloud_relay import CloudRelayWorker
from .exporter import export_day
from .identity import load_or_create_identity, register_device
from .local_relay import LocalRelayConsumer
from .normalizer import normalize_day, normalize_range
from .normalization_worker import NormalizationWorker
from .retention import LocalRelayRetention
from .settings import AppPaths
from .v2_ingestion import BatchIngestionService


def _add_v2_storage_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--data-root",
        type=Path,
        default=None,
        help="State directory; defaults to HEALTH_TRACKER_HOME or the platform data directory",
    )
    parser.add_argument("--database", type=Path, default=None, help="Override the SQLite path")


def _v2_runtime(args: argparse.Namespace):
    paths = AppPaths(args.data_root.expanduser().resolve()) if args.data_root else AppPaths.default()
    paths.ensure()
    database = Database(args.database.expanduser().resolve() if args.database else paths.database)
    identity = load_or_create_identity(paths, database)
    return paths, database, identity


def _backup_state(paths: AppPaths, database: Database, output: Path) -> Path:
    """Create a consistent, portable archive without copying a live WAL file."""
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="health-tracker-backup-") as temporary:
        staging = Path(temporary) / "health-tracker"
        staging.mkdir()
        with database.connect() as source, sqlite3.connect(staging / "health.sqlite3") as destination:
            source.backup(destination)
        if paths.keys.exists():
            shutil.copytree(paths.keys, staging / "keys")
        manifest = {
            "format": "health-tracker-backup/1",
            "created_at": datetime.now().astimezone().isoformat(),
            "includes": ["health.sqlite3", "keys"],
        }
        (staging / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        base_name = output.with_suffix("") if output.suffix == ".zip" else output
        archive = Path(shutil.make_archive(str(base_name), "zip", staging))
        archive.chmod(0o600)
    return archive


def _restore_state(archive: Path, paths: AppPaths) -> dict[str, str]:
    archive = archive.expanduser().resolve()
    root = paths.root.expanduser().resolve()
    if root.exists() and any(root.iterdir()):
        raise ValueError("restore target must be a new or empty directory")
    with zipfile.ZipFile(archive) as source:
        names = set(source.namelist())
        if "manifest.json" not in names or "health.sqlite3" not in names:
            raise ValueError("archive is not a health-tracker-backup/1 bundle")
        manifest = json.loads(source.read("manifest.json"))
        if manifest.get("format") != "health-tracker-backup/1":
            raise ValueError("unsupported backup format")
        allowed = {
            name
            for name in names
            if name in {"manifest.json", "health.sqlite3"}
            or (
                name.startswith("keys/")
                and not name.endswith("/")
                and Path(name).name == name.removeprefix("keys/")
                and Path(name).suffix == ".json"
            )
        }
        unexpected = names - allowed - {"keys/"}
        if unexpected:
            raise ValueError("backup contains unexpected paths")
        root.mkdir(parents=True, exist_ok=True)
        (root / "keys").mkdir()
        (root / "health.sqlite3").write_bytes(source.read("health.sqlite3"))
        (root / "health.sqlite3").chmod(0o600)
        for name in sorted(allowed):
            if not name.startswith("keys/"):
                continue
            target = root / "keys" / Path(name).name
            target.write_bytes(source.read(name))
            target.chmod(0o600)
    database = Database(root / "health.sqlite3")
    identity = load_or_create_identity(paths, database)
    return {"data_root": str(root), "receiver_key_id": identity.key_id}


def main() -> None:
    parser = argparse.ArgumentParser(description="Personal Apple Health receiver tools")
    subparsers = parser.add_subparsers(dest="command", required=True)

    hash_parser = subparsers.add_parser("hash-token", help="Print a SHA-256 token hash for receiver configuration")
    hash_parser.add_argument("token")

    export_parser = subparsers.add_parser("export", help="Export one analysis day as JSON")
    export_parser.add_argument(
        "--date",
        type=date.fromisoformat,
        help="Analysis date; defaults to yesterday in --timezone",
    )
    export_parser.add_argument("--timezone", default="Asia/Shanghai")
    export_parser.add_argument("--database", default=os.environ.get("HEALTH_RECEIVER_DB", "receiver/data/health.sqlite3"))
    output_group = export_parser.add_mutually_exclusive_group()
    output_group.add_argument("--output", type=Path)
    output_group.add_argument(
        "--output-dir",
        type=Path,
        help="Write health-YYYY-MM-DD.json into this directory",
    )

    normalize_parser = subparsers.add_parser(
        "normalize",
        help="Rebuild source-aware normalized projections from raw HealthKit rows",
    )
    normalize_parser.add_argument("--timezone", default="Asia/Shanghai")
    normalize_parser.add_argument(
        "--database", default=os.environ.get("HEALTH_RECEIVER_DB", "receiver/data/health.sqlite3")
    )
    normalize_parser.add_argument("--date", type=date.fromisoformat, help="Normalize one date")
    normalize_parser.add_argument("--from-date", type=date.fromisoformat, help="First date to normalize")
    normalize_parser.add_argument("--to-date", type=date.fromisoformat, help="Last date to normalize")
    normalize_parser.add_argument(
        "--days",
        type=int,
        default=7,
        help="Without --date/--from-date, normalize this many days ending today",
    )

    init_parser = subparsers.add_parser(
        "v2-init", help="Initialize portable receiver state and print the phone pairing payload"
    )
    _add_v2_storage_arguments(init_parser)

    pairing_parser = subparsers.add_parser("v2-pairing", help="Print receiver public pairing data")
    _add_v2_storage_arguments(pairing_parser)

    register_parser = subparsers.add_parser(
        "v2-register-device", help="Register an iPhone Ed25519 signing public key"
    )
    _add_v2_storage_arguments(register_parser)
    register_parser.add_argument("--owner-id", default="owner-default")
    register_parser.add_argument("--device-id", required=True)
    register_parser.add_argument("--name", default="iPhone")
    register_parser.add_argument("--signing-key-id", required=True)
    register_parser.add_argument("--signing-public-key-base64", required=True)

    consume_parser = subparsers.add_parser(
        "v2-consume-once", help="Consume encrypted .henv objects currently in relay/inbox"
    )
    _add_v2_storage_arguments(consume_parser)
    consume_parser.add_argument("--limit", type=int, default=100)

    jobs_parser = subparsers.add_parser(
        "v2-normalize-jobs", help="Process pending dates created by encrypted batch ingestion"
    )
    _add_v2_storage_arguments(jobs_parser)
    jobs_parser.add_argument("--limit", type=int, default=25)

    cloud_parser = subparsers.add_parser(
        "v2-cloud-poll-once", help="Download, verify and commit encrypted S3 relay packs"
    )
    _add_v2_storage_arguments(cloud_parser)
    cloud_parser.add_argument("--limit", type=int, default=10)

    retention_parser = subparsers.add_parser(
        "v2-retention-cleanup",
        help="Delete only confirmed Relay objects older than the configured retention",
    )
    _add_v2_storage_arguments(retention_parser)
    retention_parser.add_argument("--retention-days", type=int, default=None)

    backup_parser = subparsers.add_parser(
        "v2-backup", help="Create a portable zip containing the database and receiver keys"
    )
    _add_v2_storage_arguments(backup_parser)
    backup_parser.add_argument("--output", type=Path, required=True)

    restore_parser = subparsers.add_parser(
        "v2-restore", help="Restore a portable backup into a new empty state directory"
    )
    restore_parser.add_argument("--archive", type=Path, required=True)
    restore_parser.add_argument("--data-root", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "hash-token":
        print(hashlib.sha256(args.token.encode("utf-8")).hexdigest())
        return

    if args.command == "v2-restore":
        payload = _restore_state(args.archive, AppPaths(args.data_root))
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.command in {
        "v2-init",
        "v2-pairing",
        "v2-register-device",
        "v2-consume-once",
        "v2-normalize-jobs",
        "v2-cloud-poll-once",
        "v2-retention-cleanup",
        "v2-backup",
    }:
        paths, database, identity = _v2_runtime(args)
        if args.command in {"v2-init", "v2-pairing"}:
            payload = identity.pairing_payload()
            payload["data_root"] = str(paths.root)
        elif args.command == "v2-register-device":
            payload = register_device(
                database,
                args.owner_id,
                args.device_id,
                args.name,
                args.signing_key_id,
                args.signing_public_key_base64,
            )
        elif args.command == "v2-consume-once":
            ingestion = BatchIngestionService(database, identity)
            payload = LocalRelayConsumer(paths, ingestion).consume_once(args.limit).as_dict()
        elif args.command == "v2-normalize-jobs":
            payload = NormalizationWorker(database).run_once(args.limit).as_dict()
        elif args.command == "v2-cloud-poll-once":
            ingestion = BatchIngestionService(database, identity)
            payload = CloudRelayWorker(paths, database, ingestion).poll_once(args.limit).as_dict()
        elif args.command == "v2-retention-cleanup":
            payload = LocalRelayRetention(paths, database).cleanup(args.retention_days).as_dict()
        else:
            payload = {"archive": str(_backup_state(paths, database, args.output))}
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if args.command == "normalize":
        database = Database(args.database)
        today = datetime.now(ZoneInfo(args.timezone)).date()
        if args.date:
            start_date = end_date = args.date
        elif args.from_date:
            start_date = args.from_date
            end_date = args.to_date or today
        else:
            if args.days < 1:
                parser.error("--days must be at least 1")
            end_date = args.to_date or today
            start_date = end_date - timedelta(days=args.days - 1)
        results = normalize_range(database, start_date, end_date, args.timezone)
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return

    target_date = args.date or (datetime.now(ZoneInfo(args.timezone)).date() - timedelta(days=1))
    database = Database(args.database)
    normalize_day(database, target_date, args.timezone)
    payload = export_day(database, target_date, args.timezone)
    rendered = json.dumps(payload, ensure_ascii=False, indent=2)
    output = args.output
    if args.output_dir:
        output = args.output_dir / f"health-{target_date.isoformat()}.json"
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered + "\n", encoding="utf-8")
        print(output.resolve())
    else:
        print(rendered)


if __name__ == "__main__":
    main()
