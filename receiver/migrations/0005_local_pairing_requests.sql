CREATE TABLE local_pairing_requests (
    request_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    poll_token_hash TEXT NOT NULL,
    device_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    signing_key_id TEXT NOT NULL,
    signing_public_key_base64 TEXT NOT NULL,
    remote_address TEXT,
    status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected', 'expired', 'superseded')),
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    resolved_at TEXT,
    FOREIGN KEY (owner_id) REFERENCES owners(owner_id)
);

CREATE INDEX idx_local_pairing_requests_pending
    ON local_pairing_requests(status, expires_at, created_at);

CREATE INDEX idx_local_pairing_requests_device
    ON local_pairing_requests(device_id, created_at);
