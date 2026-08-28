from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import random
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Mapping

from .database import Database
from .settings import AppPaths
from .v2_ingestion import BatchIngestionService, IngestionError


BOOTSTRAP_CONTENT_TYPE = "application/vnd.health-cloud-bootstrap+json;v=1"
BOOTSTRAP_PROTOCOL = "health-cloud-bootstrap/1"
PACK_PROTOCOL = "health-relay-pack/1"
RECEIPT_PROTOCOL = "health-cloud-receipt/1"
RECEIPT_PREFIX = b"HEALTH-CLOUD-RECEIPT-V1\x00"
MAX_PACK_BYTES = 128 * 1024 * 1024


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _atomic_private_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".cloud-relay-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@dataclass(frozen=True)
class CloudRelayConfig:
    owner_id: str
    device_id: str
    endpoint: str
    region: str
    bucket: str
    prefix: str
    path_style: bool
    retention_days: int
    access_key: str
    secret_key: str
    receipt_hmac_key: bytes

    @property
    def inbox_prefix(self) -> str:
        return "/".join(part for part in (self.prefix, "inbox", self.device_id) if part) + "/"

    @property
    def receipt_prefix(self) -> str:
        return "/".join(part for part in (self.prefix, "receipts", self.device_id) if part) + "/"

    def public_summary(self) -> dict[str, Any]:
        return {
            "provider": "s3",
            "endpoint": self.endpoint,
            "region": self.region,
            "bucket": self.bucket,
            "prefix": self.prefix,
            "path_style": self.path_style,
            "retention_days": self.retention_days,
            "device_id": self.device_id,
        }


def _validated_config(payload: Mapping[str, Any], authenticated_device: Mapping[str, Any]) -> CloudRelayConfig:
    if payload.get("protocol") != BOOTSTRAP_PROTOCOL or payload.get("provider") != "s3":
        raise IngestionError("unsupported cloud bootstrap protocol or provider")
    if payload.get("device_id") != authenticated_device["device_id"]:
        raise IngestionError("cloud bootstrap device does not match its signature")
    if payload.get("owner_id") != authenticated_device["owner_id"]:
        raise IngestionError("cloud bootstrap owner does not match registered device")
    endpoint = str(payload.get("endpoint", "")).strip().rstrip("/")
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme != "https" or not parsed.hostname or parsed.query or parsed.fragment:
        raise IngestionError("cloud endpoint must be a plain HTTPS origin")
    region = str(payload.get("region", "")).strip()
    bucket = str(payload.get("bucket", "")).strip()
    prefix = "/".join(str(payload.get("prefix", "")).strip().strip("/").split("/"))
    access_key = str(payload.get("access_key", "")).strip()
    secret_key = str(payload.get("secret_key", ""))
    if not all((region, bucket, access_key, secret_key)):
        raise IngestionError("cloud bootstrap is missing required S3 fields")
    if any(value in bucket for value in ("/", "\\", "\x00")):
        raise IngestionError("invalid S3 bucket")
    retention_days = payload.get("retention_days")
    if not isinstance(retention_days, int) or not 1 <= retention_days <= 365:
        raise IngestionError("cloud retention must be 1 to 365 days")
    try:
        receipt_hmac_key = base64.b64decode(payload["receipt_hmac_key_base64"], validate=True)
    except Exception as exc:
        raise IngestionError("invalid receipt authentication key") from exc
    if len(receipt_hmac_key) != 32:
        raise IngestionError("receipt authentication key must be 32 bytes")
    return CloudRelayConfig(
        owner_id=str(payload["owner_id"]), device_id=str(payload["device_id"]),
        endpoint=endpoint, region=region, bucket=bucket, prefix=prefix,
        path_style=bool(payload.get("path_style", True)), retention_days=retention_days,
        access_key=access_key, secret_key=secret_key, receipt_hmac_key=receipt_hmac_key,
    )


class CloudBootstrapStore:
    """Stores only the phone-signed HPKE ciphertext; plaintext credentials never touch disk."""

    def __init__(self, paths: AppPaths, ingestion: BatchIngestionService) -> None:
        self.paths = paths
        self.ingestion = ingestion

    def save(self, envelope: Mapping[str, Any]) -> CloudRelayConfig:
        opened, device = self.ingestion.open_authenticated_envelope(
            envelope, expected_content_type=BOOTSTRAP_CONTENT_TYPE
        )
        config = _validated_config(opened.payload, device)
        _atomic_private_json(self._path(config.device_id), envelope)
        return config

    def load_all(self) -> list[CloudRelayConfig]:
        output: list[CloudRelayConfig] = []
        for path in sorted(self.paths.keys.glob("cloud-relay-*.json")):
            envelope = json.loads(path.read_text(encoding="utf-8"))
            opened, device = self.ingestion.open_authenticated_envelope(
                envelope, expected_content_type=BOOTSTRAP_CONTENT_TYPE
            )
            output.append(_validated_config(opened.payload, device))
        return output

    def _path(self, device_id: str) -> Path:
        digest = hashlib.sha256(device_id.encode()).hexdigest()[:24]
        return self.paths.keys / f"cloud-relay-{digest}.json"


class S3Error(RuntimeError):
    pass


class S3Client:
    """Small SigV4 client with the exact Data Capsule/Rclone compatibility profile."""

    def __init__(self, config: CloudRelayConfig) -> None:
        self.config = config
        self._next_request_at = 0.0

    def list_objects(self, prefix: str, max_keys: int = 100) -> list[str]:
        keys: list[str] = []
        token: str | None = None
        while True:
            query = [("list-type", "2"), ("max-keys", str(max_keys)), ("prefix", prefix)]
            if token:
                query.append(("continuation-token", token))
            data = self._request("GET", None, query=query)
            try:
                root = ET.fromstring(data)
            except ET.ParseError as exc:
                raise S3Error("S3 returned invalid ListObjectsV2 XML") from exc
            for node in root.findall(".//{*}Contents/{*}Key"):
                if node.text:
                    keys.append(node.text)
            truncated = (root.findtext(".//{*}IsTruncated") or "false").lower() == "true"
            token = root.findtext(".//{*}NextContinuationToken")
            if not truncated or not token or len(keys) >= max_keys:
                return keys[:max_keys]

    def get(self, key: str) -> bytes:
        return self._request("GET", key)

    def put(self, key: str, body: bytes, content_type: str = "application/json") -> None:
        self._request("PUT", key, body=body, content_type=content_type)

    def delete(self, key: str) -> None:
        self._request("DELETE", key)

    def _request(
        self,
        method: str,
        key: str | None,
        *,
        query: list[tuple[str, str]] | None = None,
        body: bytes = b"",
        content_type: str | None = None,
    ) -> bytes:
        url = self._url(key, query or [])
        for attempt in range(4):
            self._throttle()
            request = urllib.request.Request(url, data=body if method == "PUT" else None, method=method)
            if content_type:
                request.add_header("Content-Type", content_type)
            for name, value in self._signed_headers(method, url, body).items():
                request.add_header(name, value)
            try:
                with urllib.request.urlopen(request, timeout=45) as response:
                    return response.read(MAX_PACK_BYTES + 1)
            except urllib.error.HTTPError as exc:
                response_body = exc.read(2048).decode("utf-8", "replace")
                if exc.code not in {408, 425, 429, 500, 502, 503, 504} or attempt == 3:
                    raise S3Error(f"S3 HTTP {exc.code}: {response_body[:500]}") from exc
                retry_after = exc.headers.get("Retry-After")
                delay = float(retry_after) if retry_after and retry_after.isdigit() else 2**attempt
                time.sleep(min(delay, 30) + random.uniform(0.1, 0.7))
            except urllib.error.URLError as exc:
                if attempt == 3:
                    raise S3Error(f"S3 network error: {exc.reason}") from exc
                time.sleep(2**attempt + random.uniform(0.1, 0.7))
        raise S3Error("S3 request failed")

    def _throttle(self) -> None:
        delay = self._next_request_at - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        spacing = 1.25 if urllib.parse.urlsplit(self.config.endpoint).hostname == "s3.cstcloud.cn" else 0
        self._next_request_at = time.monotonic() + spacing

    def _url(self, key: str | None, query: list[tuple[str, str]]) -> str:
        parsed = urllib.parse.urlsplit(self.config.endpoint)
        pieces = [part for part in parsed.path.split("/") if part]
        host = parsed.netloc
        if self.config.path_style:
            pieces.append(self.config.bucket)
        else:
            host = f"{self.config.bucket}.{host}"
        if key:
            pieces.extend(part for part in key.split("/") if part)
        path = "/" + "/".join(urllib.parse.quote(part, safe="-._~") for part in pieces)
        encoded_query = urllib.parse.urlencode(sorted(query), quote_via=urllib.parse.quote, safe="-._~")
        return urllib.parse.urlunsplit((parsed.scheme, host, path, encoded_query, ""))

    def _signed_headers(self, method: str, url: str, body: bytes) -> dict[str, str]:
        parsed = urllib.parse.urlsplit(url)
        now = datetime.now(UTC)
        date_stamp = now.strftime("%Y%m%d")
        timestamp = now.strftime("%Y%m%dT%H%M%SZ")
        payload_hash = hashlib.sha256(body).hexdigest()
        host = parsed.netloc
        signed_headers = "host;x-amz-content-sha256;x-amz-date"
        canonical_headers = (
            f"host:{host}\n"
            f"x-amz-content-sha256:{payload_hash}\n"
            f"x-amz-date:{timestamp}\n"
        )
        canonical_request = "\n".join((
            method, parsed.path or "/", parsed.query, canonical_headers,
            signed_headers, payload_hash,
        ))
        scope = f"{date_stamp}/{self.config.region}/s3/aws4_request"
        string_to_sign = "\n".join((
            "AWS4-HMAC-SHA256", timestamp, scope,
            hashlib.sha256(canonical_request.encode()).hexdigest(),
        ))
        date_key = hmac.new(("AWS4" + self.config.secret_key).encode(), date_stamp.encode(), hashlib.sha256).digest()
        region_key = hmac.new(date_key, self.config.region.encode(), hashlib.sha256).digest()
        service_key = hmac.new(region_key, b"s3", hashlib.sha256).digest()
        signing_key = hmac.new(service_key, b"aws4_request", hashlib.sha256).digest()
        signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
        headers = {
            "Host": host,
            "x-amz-date": timestamp,
            "x-amz-content-sha256": payload_hash,
            "Authorization": (
                f"AWS4-HMAC-SHA256 Credential={self.config.access_key}/{scope}, "
                f"SignedHeaders={signed_headers}, Signature={signature}"
            ),
        }
        if parsed.hostname == "s3.cstcloud.cn":
            headers["User-Agent"] = "rclone/v1.75.0"
        return headers


def receipt_material(receipt: Mapping[str, Any]) -> bytes:
    fields = (
        str(receipt["device_id"]), str(receipt["object_key"]), str(receipt["pack_id"]),
        str(receipt["committed_at"]), ",".join(str(value) for value in receipt["batch_ids"]),
    )
    return RECEIPT_PREFIX + "\x00".join(fields).encode("utf-8")


@dataclass
class CloudPollResult:
    configured: int = 0
    discovered: int = 0
    committed_packs: int = 0
    committed_batches: int = 0
    duplicates: int = 0
    failed: int = 0
    deleted: int = 0

    def as_dict(self) -> dict[str, int]:
        return vars(self)


class CloudRelayWorker:
    def __init__(
        self,
        paths: AppPaths,
        database: Database,
        ingestion: BatchIngestionService,
        client_factory: Callable[[CloudRelayConfig], S3Client] = S3Client,
    ) -> None:
        self.paths = paths
        self.database = database
        self.ingestion = ingestion
        self.store = CloudBootstrapStore(paths, ingestion)
        self.client_factory = client_factory

    def poll_once(self, limit: int = 10) -> CloudPollResult:
        result = CloudPollResult()
        for config in self.store.load_all():
            result.configured += 1
            client = self.client_factory(config)
            self._cleanup(client, config, result)
            keys = [
                key for key in client.list_objects(config.inbox_prefix, max_keys=1000)
                if key.endswith(".hpack")
            ]
            result.discovered += len(keys)
            processed = 0
            for key in keys:
                existing = self.database.fetch_all(
                    "SELECT status FROM cloud_relay_objects WHERE device_id=? AND object_key=?",
                    (config.device_id, key),
                )
                if existing and existing[0]["status"] == "committed":
                    continue
                if processed >= limit:
                    break
                processed += 1
                try:
                    self._consume(client, config, key, result)
                except Exception as exc:
                    result.failed += 1
                    now = _now()
                    with self.database.connection() as connection:
                        connection.execute(
                            """INSERT INTO cloud_relay_objects(
                                   device_id, object_key, status, attempts, first_seen_at, error_message
                               ) VALUES (?, ?, 'failed', 1, ?, ?)
                               ON CONFLICT(device_id, object_key) DO UPDATE SET
                                   status='failed', attempts=attempts+1, error_message=excluded.error_message""",
                            (config.device_id, key, now, str(exc)[:1000]),
                        )
        return result

    def _consume(self, client: S3Client, config: CloudRelayConfig, key: str, result: CloudPollResult) -> None:
        body = client.get(key)
        if len(body) > MAX_PACK_BYTES:
            raise IngestionError("cloud relay pack is too large")
        try:
            pack = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise IngestionError("cloud relay pack is not valid JSON") from exc
        if pack.get("protocol") != PACK_PROTOCOL or pack.get("device_id") != config.device_id:
            raise IngestionError("cloud relay pack identity is invalid")
        pack_id = pack.get("pack_id")
        envelopes = pack.get("envelopes")
        if not isinstance(pack_id, str) or not pack_id or not isinstance(envelopes, list) or not 1 <= len(envelopes) <= 128:
            raise IngestionError("cloud relay pack shape is invalid")
        headers = [self.ingestion.open_authenticated_envelope(envelope)[0].header for envelope in envelopes]
        sequences = [int(header["sequence"]) for header in headers]
        if sequences != sorted(sequences) or len(sequences) != len(set(sequences)):
            raise IngestionError("cloud relay pack sequences are not unique and ordered")
        if any(header["device_id"] != config.device_id for header in headers):
            raise IngestionError("cloud relay pack contains another device")
        receipts = [
            self.ingestion.ingest(envelope, object_key=f"s3:{key}#{index + 1}")
            for index, envelope in enumerate(envelopes)
        ]
        committed_at = _now()
        receipt: dict[str, Any] = {
            "protocol": RECEIPT_PROTOCOL,
            "device_id": config.device_id,
            "object_key": key,
            "pack_id": pack_id,
            "committed_at": committed_at,
            "batch_ids": [str(header["batch_id"]) for header in headers],
        }
        receipt["hmac_sha256"] = hmac.new(
            config.receipt_hmac_key, receipt_material(receipt), hashlib.sha256
        ).hexdigest()
        receipt_key = config.receipt_prefix + pack_id + ".json"
        encoded_receipt = json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        client.put(receipt_key, encoded_receipt)
        delete_after = (datetime.now(UTC) + timedelta(days=config.retention_days)).isoformat()
        with self.database.connection() as connection:
            connection.execute(
                """INSERT INTO cloud_relay_objects(
                       device_id, object_key, pack_id, receipt_key, status, attempts,
                       first_seen_at, processed_at, delete_after, error_message
                   ) VALUES (?, ?, ?, ?, 'committed', 1, ?, ?, ?, NULL)
                   ON CONFLICT(device_id, object_key) DO UPDATE SET
                       pack_id=excluded.pack_id, receipt_key=excluded.receipt_key,
                       status='committed', attempts=attempts+1,
                       processed_at=excluded.processed_at, delete_after=excluded.delete_after,
                       error_message=NULL""",
                (config.device_id, key, pack_id, receipt_key, committed_at, committed_at, delete_after),
            )
        result.committed_packs += 1
        result.committed_batches += sum(not receipt.get("duplicate") for receipt in receipts)
        result.duplicates += sum(bool(receipt.get("duplicate")) for receipt in receipts)

    def _cleanup(self, client: S3Client, config: CloudRelayConfig, result: CloudPollResult) -> None:
        due = self.database.fetch_all(
            """SELECT object_key FROM cloud_relay_objects
               WHERE device_id=? AND status='committed' AND deleted_at IS NULL
                 AND delete_after IS NOT NULL AND delete_after <= ? LIMIT 25""",
            (config.device_id, datetime.now(UTC).isoformat()),
        )
        for row in due:
            client.delete(row["object_key"])
            with self.database.connection() as connection:
                connection.execute(
                    "UPDATE cloud_relay_objects SET deleted_at=?, status='deleted' WHERE device_id=? AND object_key=?",
                    (_now(), config.device_id, row["object_key"]),
                )
            result.deleted += 1
