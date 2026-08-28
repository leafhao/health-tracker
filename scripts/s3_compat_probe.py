#!/usr/bin/env python3
"""Small dependency-free SigV4 probe for S3-compatible services.

Credentials are read interactively and are never written to disk or printed.
"""

from __future__ import annotations

import datetime as dt
import getpass
import hashlib
import hmac
import urllib.error
import urllib.parse
import urllib.request


def _hmac(key: bytes, value: str) -> bytes:
    return hmac.new(key, value.encode(), hashlib.sha256).digest()


def _authorization(
    *,
    method: str,
    host: str,
    path: str,
    query: str,
    region: str,
    access_key: str,
    secret_key: str,
    timestamp: dt.datetime,
) -> tuple[str, dict[str, str]]:
    amz_date = timestamp.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = timestamp.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_headers = (
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join(
        [method, path, query, canonical_headers, signed_headers, payload_hash]
    )
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode()).hexdigest(),
        ]
    )
    date_key = _hmac(("AWS4" + secret_key).encode(), date_stamp)
    region_key = _hmac(date_key, region)
    service_key = _hmac(region_key, "s3")
    signing_key = _hmac(service_key, "aws4_request")
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
    authorization = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    return authorization, {
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
    }


def probe(endpoint: str, bucket: str, region: str, access_key: str, secret_key: str) -> None:
    endpoint = endpoint.strip().rstrip("/")
    if "://" not in endpoint:
        endpoint = "https://" + endpoint
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme != "https" or not parsed.hostname:
        raise SystemExit("Endpoint must resolve to an HTTPS host")
    host = parsed.netloc
    path = "/" + urllib.parse.quote(bucket, safe="-_.~")
    query = "list-type=2&max-keys=1"
    url = urllib.parse.urlunsplit((parsed.scheme, host, path, query, ""))
    profiles = [
        "HealthBeat/1.0",
        "rclone/v1.75.0",
        "rclone/v1.68.0",
        "aws-sdk-js/3.620.0 ua/2.1 api/s3#3.620.0",
    ]
    for user_agent in profiles:
        authorization, signed = _authorization(
            method="GET",
            host=host,
            path=path,
            query=query,
            region=region,
            access_key=access_key,
            secret_key=secret_key,
            timestamp=dt.datetime.now(dt.UTC),
        )
        request = urllib.request.Request(
            url,
            method="GET",
            headers={
                **signed,
                "Authorization": authorization,
                "User-Agent": user_agent,
                "Cache-Control": "no-cache",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = response.read(500).decode("utf-8", "replace")
                print(f"{user_agent}: HTTP {response.status}; {body[:160]!r}")
        except urllib.error.HTTPError as error:
            body = error.read(500).decode("utf-8", "replace")
            print(f"{user_agent}: HTTP {error.code}; {body[:160]!r}")
        except Exception as error:
            print(f"{user_agent}: {type(error).__name__}: {error}")


if __name__ == "__main__":
    endpoint = input("Endpoint: ").strip()
    bucket = input("Bucket: ").strip()
    region = input("Region [us-east-1]: ").strip() or "us-east-1"
    access_key = getpass.getpass("Access Key ID: ").strip()
    secret_key = getpass.getpass("Access Key Secret: ").strip()
    probe(endpoint, bucket, region, access_key, secret_key)
