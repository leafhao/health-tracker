from __future__ import annotations

import asyncio
import hashlib
import hmac
import ipaddress
import os
import subprocess
import sys
import time
from contextlib import asynccontextmanager, suppress
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse

from .access_control import AccessControl, AccessControlError
from .agent_api import _require_local_agent, mount_agent_api
from .cloud_relay import CloudBootstrapStore
from .database import Database
from .discovery import BonjourPublisher
from .dashboard import mount_dashboard
from .exporter import export_day
from .identity import load_or_create_identity
from .models import (
    ActivitySummary,
    CategorySample,
    Envelope,
    IngestResponse,
    QuantitySample,
    ReconcileRequest,
    Workout,
    WorkoutRoute,
)
from .normalization_worker import NormalizationWorker
from .retention import configured_retention_days
from .settings import AppPaths
from .sync_crypto import EnvelopeError, peek_header
from .v2_ingestion import BatchIngestionService, IngestionError
from .worker import (
    CLOUD_RELAY_WORKER,
    NORMALIZATION_WORKER,
    heartbeat_age_seconds,
    worker_heartbeat,
)


MAX_DIRECT_PACK_ENVELOPES = 128
DIRECT_PACK_PROTOCOL = "health-relay-pack/1"


def _validate_direct_pack(payload: dict[str, Any]) -> tuple[str, str, list[dict[str, Any]]]:
    if payload.get("protocol") != DIRECT_PACK_PROTOCOL:
        raise IngestionError("unsupported direct pack protocol")
    pack_id = payload.get("pack_id")
    device_id = payload.get("device_id")
    if not isinstance(pack_id, str) or not pack_id or any(char in pack_id for char in "/\\\0"):
        raise IngestionError("invalid direct pack id")
    if not isinstance(device_id, str) or not device_id:
        raise IngestionError("invalid direct pack device id")
    envelopes = payload.get("envelopes")
    if not isinstance(envelopes, list) or not 1 <= len(envelopes) <= MAX_DIRECT_PACK_ENVELOPES:
        raise IngestionError("direct pack must contain 1 to 128 envelopes")

    headers = []
    for envelope in envelopes:
        if not isinstance(envelope, dict):
            raise IngestionError("direct pack envelope must be a JSON object")
        header = peek_header(envelope)
        if header.get("device_id") != device_id:
            raise IngestionError("direct pack contains an envelope for another device")
        headers.append(header)
    sequences = [int(header["sequence"]) for header in headers]
    if sequences != sorted(sequences) or len(sequences) != len(set(sequences)):
        raise IngestionError("direct pack sequences must be unique and ordered")
    if payload.get("first_sequence") != sequences[0] or payload.get("last_sequence") != sequences[-1]:
        raise IngestionError("direct pack sequence range does not match its envelopes")
    return pack_id, device_id, envelopes


def _verify_token(authorization: Annotated[str | None, Header()] = None) -> None:
    expected_hash = os.environ.get("HEALTH_RECEIVER_TOKEN_SHA256", "").lower()
    if not expected_hash:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="receiver token is not configured")
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="missing bearer token")
    supplied_hash = hashlib.sha256(authorization[7:].encode("utf-8")).hexdigest()
    if not hmac.compare_digest(supplied_hash, expected_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid bearer token")


Auth = Annotated[None, Depends(_verify_token)]


def _is_local_pairing_client(value: str | None) -> bool:
    if value == "testclient":
        return True
    if not value:
        return False
    try:
        address = ipaddress.ip_address(value.split("%", 1)[0])
    except ValueError:
        return False
    return address.is_private or address.is_loopback or address.is_link_local


def create_app(
    database_path: str | Path | None = None,
    data_root: str | Path | None = None,
) -> FastAPI:
    if data_root is not None:
        paths = AppPaths(Path(data_root).expanduser().resolve())
        resolved_path = Path(database_path).expanduser().resolve() if database_path else paths.database
    else:
        resolved_path = Path(
            database_path or os.environ.get("HEALTH_RECEIVER_DB", "receiver/data/health.sqlite3")
        ).expanduser().resolve()
        paths = AppPaths(resolved_path.parent)
    paths.ensure()
    database = Database(resolved_path)
    identity = load_or_create_identity(paths, database)
    access_control = AccessControl(database)
    batch_ingestion = BatchIngestionService(database, identity)
    normalization_worker = NormalizationWorker(database)
    bonjour = BonjourPublisher(identity)
    cloud_bootstrap_store = CloudBootstrapStore(paths, batch_ingestion)
    cloud_relay_enabled = os.environ.get("HEALTH_RECEIVER_DISABLE_CLOUD_RELAY") != "1"
    external_workers = os.environ.get("HEALTH_RECEIVER_WORKERS_EXTERNAL") == "1"
    runtime_status: dict[str, Any] = {
        "started_monotonic": time.monotonic(),
        "normalization_heartbeat": time.monotonic(),
        "cloud_relay_heartbeat": time.monotonic(),
        "cloud_relay_enabled": cloud_relay_enabled,
    }

    async def normalization_loop() -> None:
        normalization_worker.recover_interrupted_jobs()
        while True:
            runtime_status["normalization_heartbeat"] = time.monotonic()
            if normalization_worker.ingestion_is_active(quiet_seconds=15):
                await asyncio.sleep(2)
                continue
            process = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m",
                "receiver.cli",
                "v2-normalize-jobs",
                "--database",
                str(database.path),
                "--limit",
                "10",
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                await process.wait()
            except asyncio.CancelledError:
                process.terminate()
                await process.wait()
                raise
            runtime_status["normalization_heartbeat"] = time.monotonic()
            await asyncio.sleep(0.5 if process.returncode == 0 else 5)

    async def cloud_relay_loop() -> None:
        """Run network relay work outside the web process and its event loop."""
        await asyncio.sleep(5)
        while True:
            runtime_status["cloud_relay_heartbeat"] = time.monotonic()
            process = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m",
                "receiver.cli",
                "v2-cloud-poll-once",
                "--data-root",
                str(paths.root),
                "--database",
                str(database.path),
                "--limit",
                "10",
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                await process.wait()
            except asyncio.CancelledError:
                process.terminate()
                await process.wait()
                raise
            runtime_status["cloud_relay_heartbeat"] = time.monotonic()
            await asyncio.sleep(30 if process.returncode == 0 else 90)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        normalization_task = (
            None if external_workers else asyncio.create_task(normalization_loop())
        )
        cloud_relay_task = (
            None
            if not cloud_relay_enabled or external_workers
            else asyncio.create_task(cloud_relay_loop())
        )
        try:
            bonjour.start()
        except Exception as exc:
            # The HTTP receiver remains usable through QR/manual fallback even
            # when multicast DNS is unavailable on a particular network.
            print(f"[Receiver] Bonjour startup failed: {exc}")
        try:
            yield
        finally:
            bonjour.stop()
            if normalization_task is not None:
                normalization_task.cancel()
            if cloud_relay_task is not None:
                cloud_relay_task.cancel()
            if normalization_task is not None:
                with suppress(asyncio.CancelledError):
                    await normalization_task
            if cloud_relay_task is not None:
                with suppress(asyncio.CancelledError):
                    await cloud_relay_task

    app = FastAPI(title="Personal Health Receiver", version="0.1.0", lifespan=lifespan)
    app.state.database = database
    app.state.paths = paths
    app.state.identity = identity
    app.state.access_control = access_control
    app.state.batch_ingestion = batch_ingestion
    app.state.normalization_worker = normalization_worker
    app.state.bonjour = bonjour
    app.state.cloud_bootstrap_store = cloud_bootstrap_store
    app.state.runtime_status = runtime_status
    app.state.external_workers = external_workers

    @app.get("/api/v1/healthbeat/health")
    def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "server_time": datetime.now(timezone.utc).isoformat(),
            "schema_version": 2,
            "max_batch": 500,
        }

    @app.get("/api/v1/healthbeat/ready", include_in_schema=True)
    def readiness(request: Request):
        """Deep local readiness used by launchd watchdogs.

        This deliberately checks more than HTTP liveness without running an
        expensive full integrity scan on every probe. Daily maintenance owns
        PRAGMA quick_check and portable backup verification.
        """
        _require_local_agent(request)
        if external_workers:
            normalization_row = worker_heartbeat(database, NORMALIZATION_WORKER)
            cloud_row = worker_heartbeat(database, CLOUD_RELAY_WORKER)
            normalization_age = heartbeat_age_seconds(normalization_row)
            cloud_age = heartbeat_age_seconds(cloud_row)
        else:
            now = time.monotonic()
            normalization_row = None
            cloud_row = None
            normalization_age = now - float(runtime_status["normalization_heartbeat"])
            cloud_age = now - float(runtime_status["cloud_relay_heartbeat"])
        failures: list[str] = []
        try:
            database.fetch_all("SELECT 1 AS ok")
            pending = database.fetch_all(
                "SELECT COUNT(*) AS count FROM normalization_jobs WHERE status IN ('pending','running')"
            )[0]["count"]
            pending_snapshots = database.fetch_all(
                "SELECT COUNT(*) AS count FROM dashboard_snapshot_jobs"
            )[0]["count"]
            # `gap_detected` records what was missing when a batch first arrived.
            # Background/relay uploads may arrive out of order, so that historical
            # flag must not be reported as an open gap after the predecessor lands.
            gaps = database.fetch_all(
                """SELECT COUNT(*) AS count
                   FROM ingest_batches AS current
                   WHERE current.sequence > 1
                     AND NOT EXISTS (
                         SELECT 1 FROM ingest_batches AS previous
                         WHERE previous.owner_id = current.owner_id
                           AND previous.device_id = current.device_id
                           AND previous.sequence = current.sequence - 1
                           AND previous.batch_id = current.previous_batch_id
                     )"""
            )[0]["count"]
            database_ok = True
        except Exception as exc:
            database_ok = False
            pending = None
            pending_snapshots = None
            gaps = None
            failures.append(f"database unavailable: {type(exc).__name__}")
        if normalization_age is None or normalization_age > 600:
            failures.append("normalization worker heartbeat is stale")
        if normalization_row and normalization_row.get("status") in {"error", "stopped"}:
            failures.append(
                f"normalization worker is {normalization_row['status']}: "
                f"{normalization_row.get('last_error') or 'no detail'}"
            )
        if cloud_relay_enabled and (cloud_age is None or cloud_age > 600):
            failures.append("cloud relay heartbeat is stale")
        if (
            cloud_relay_enabled
            and cloud_row
            and cloud_row.get("status") in {"error", "stopped"}
        ):
            failures.append(
                f"cloud relay worker is {cloud_row['status']}: "
                f"{cloud_row.get('last_error') or 'no detail'}"
            )
        payload = {
            "status": "ready" if not failures else "not_ready",
            "database": "ok" if database_ok else "unavailable",
            "normalization_worker_heartbeat_age_seconds": (
                round(normalization_age, 3) if normalization_age is not None else None
            ),
            "normalization_worker_status": (
                normalization_row.get("status") if normalization_row else "embedded"
            ),
            "cloud_relay": "enabled" if cloud_relay_enabled else "disabled",
            "cloud_relay_heartbeat_age_seconds": (
                round(cloud_age, 3)
                if cloud_relay_enabled and cloud_age is not None
                else None
            ),
            "cloud_relay_worker_status": (
                cloud_row.get("status") if cloud_row else ("embedded" if cloud_relay_enabled else "disabled")
            ),
            "pending_normalization_jobs": pending,
            "pending_dashboard_snapshots": pending_snapshots,
            "sequence_gaps": gaps,
            "failures": failures,
        }
        return JSONResponse(status_code=200 if not failures else 503, content=payload)

    @app.get("/api/v2/system/identity")
    def receiver_identity() -> dict[str, Any]:
        """Public pairing material. This endpoint never exposes a private key."""
        return identity.pairing_payload()

    @app.post("/api/v2/pairing/devices")
    def pair_device(
        payload: dict[str, Any],
        pairing_code: Annotated[str | None, Header(alias="X-Health-Pairing-Code")] = None,
    ) -> dict[str, Any]:
        if not pairing_code:
            raise HTTPException(status_code=401, detail="missing one-time pairing code")
        try:
            device = access_control.register_device_with_pairing_code(pairing_code, payload)
        except AccessControlError as exc:
            raise HTTPException(status_code=401, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"device": device, "receiver": identity.pairing_payload(device["owner_id"])}

    @app.post("/api/v2/pairing/requests")
    def request_local_pairing(payload: dict[str, Any], request: Request) -> dict[str, Any]:
        remote = request.client.host if request.client else None
        if not _is_local_pairing_client(remote):
            raise HTTPException(status_code=403, detail="局域网自动配对只接受本地网络请求")
        try:
            pairing = access_control.create_local_pairing_request(payload, remote)
        except (AccessControlError, ValueError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        pairing["receiver"] = identity.pairing_payload()
        return pairing

    @app.get("/api/v2/pairing/requests/{request_id}")
    def local_pairing_status(
        request_id: str,
        poll_token: Annotated[str | None, Header(alias="X-Health-Pairing-Poll-Token")] = None,
    ) -> dict[str, Any]:
        if not poll_token:
            raise HTTPException(status_code=401, detail="missing pairing poll token")
        try:
            result = access_control.local_pairing_request_status(request_id, poll_token)
        except AccessControlError as exc:
            raise HTTPException(status_code=401, detail=str(exc)) from exc
        if result["status"] == "approved":
            result["receiver"] = identity.pairing_payload()
        return result

    @app.post("/api/v2/sync/batches")
    def ingest_encrypted_batch(payload: dict[str, Any]) -> dict[str, Any]:
        """Accept a self-authenticating encrypted batch from a registered device."""
        try:
            return batch_ingestion.ingest(payload, object_key="direct-api")
        except IngestionError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/v2/sync/packs")
    def ingest_encrypted_pack(
        payload: dict[str, Any], request: Request
    ) -> dict[str, Any]:
        """Accept one bounded pack of independently encrypted, signed batches.

        The pack is only a transport container. Every envelope is authenticated
        and committed independently, so an interrupted upload can safely retry
        the same pack without creating duplicate health records.
        """
        remote = request.client.host if request.client else None
        if not _is_local_pairing_client(remote):
            raise HTTPException(status_code=403, detail="首次历史直传只接受局域网请求")
        try:
            pack_id, device_id, envelopes = _validate_direct_pack(payload)
            receipts = [
                batch_ingestion.ingest(
                    envelope,
                    object_key=f"direct-pack:{pack_id}#{index + 1}",
                )
                for index, envelope in enumerate(envelopes)
            ]
            duplicates = sum(bool(receipt.get("duplicate")) for receipt in receipts)
            return {
                "protocol": "health-pack-receipt/1",
                "pack_id": pack_id,
                "device_id": device_id,
                "status": "committed",
                "committed": len(receipts) - duplicates,
                "duplicates": duplicates,
                "receipts": receipts,
            }
        except (EnvelopeError, IngestionError, KeyError, TypeError, ValueError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/v2/cloud/bootstrap")
    def configure_cloud_relay(payload: dict[str, Any], request: Request) -> dict[str, Any]:
        """Accept cloud credentials only inside a paired phone's signed HPKE envelope."""
        remote = request.client.host if request.client else None
        if not _is_local_pairing_client(remote):
            raise HTTPException(status_code=403, detail="云存储首次下发只接受局域网请求")
        try:
            config = cloud_bootstrap_store.save(payload)
        except (EnvelopeError, IngestionError, KeyError, TypeError, ValueError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {
            "status": "configured",
            "encryption": "HPKE-X25519 + Ed25519",
            "credentials_at_rest": "encrypted-envelope-only",
            "cloud": config.public_summary(),
        }

    @app.get("/api/v2/system/sync-status")
    def sync_status(_: Auth) -> dict[str, Any]:
        devices = database.fetch_all(
            """SELECT owner_id, device_id, display_name, status, last_sequence, last_seen_at
               FROM devices ORDER BY owner_id, device_id"""
        )
        batches = database.fetch_all(
            """SELECT owner_id, device_id, batch_id, sequence, status, event_count,
                      accepted_count, rejected_count, gap_detected, created_at, committed_at
               FROM ingest_batches ORDER BY committed_at DESC LIMIT 100"""
        )
        return {
            "devices": devices,
            "recent_batches": batches,
            "relay_retention": {
                "days": configured_retention_days(),
                "delete_unconfirmed": False,
            },
        }

    def remote_address(request: Request) -> str | None:
        return request.client.host if request.client else None

    @app.post("/api/v1/healthbeat/quantity-samples", response_model=IngestResponse)
    def ingest_quantities(payload: Envelope[QuantitySample], request: Request, _: Auth) -> IngestResponse:
        return IngestResponse(accepted=database.upsert("quantity_samples", payload.records, remote_address(request)))

    @app.post("/api/v1/healthbeat/category-samples", response_model=IngestResponse)
    def ingest_categories(payload: Envelope[CategorySample], request: Request, _: Auth) -> IngestResponse:
        return IngestResponse(accepted=database.upsert("category_samples", payload.records, remote_address(request)))

    @app.post("/api/v1/healthbeat/workouts", response_model=IngestResponse)
    def ingest_workouts(payload: Envelope[Workout], request: Request, _: Auth) -> IngestResponse:
        return IngestResponse(accepted=database.upsert("workouts", payload.records, remote_address(request)))

    @app.post("/api/v1/healthbeat/workout-routes", response_model=IngestResponse)
    def ingest_routes(payload: Envelope[WorkoutRoute], request: Request, _: Auth) -> IngestResponse:
        return IngestResponse(accepted=database.upsert("workout_routes", payload.records, remote_address(request)))

    @app.post("/api/v1/healthbeat/activity-summaries", response_model=IngestResponse)
    def ingest_activity(payload: Envelope[ActivitySummary], request: Request, _: Auth) -> IngestResponse:
        return IngestResponse(accepted=database.upsert("activity_summaries", payload.records, remote_address(request)))

    @app.post("/api/v1/healthbeat/reconcile")
    def reconcile(payload: ReconcileRequest, _: Auth) -> dict[str, int]:
        try:
            deleted = database.reconcile(
                payload.table,
                payload.type_column,
                payload.type_value,
                payload.since,
                payload.until,
                payload.valid_uuids,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"deleted": deleted}

    @app.get("/api/v1/days/{target_date}")
    def get_day(target_date: date, _: Auth, timezone_name: str = "Asia/Shanghai") -> dict[str, Any]:
        try:
            return export_day(database, target_date, timezone_name)
        except (KeyError, ValueError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    mount_dashboard(app, database, access_control, identity, paths)
    mount_agent_api(app, database)
    return app


app = create_app()
