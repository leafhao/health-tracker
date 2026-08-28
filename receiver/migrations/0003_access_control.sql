CREATE TABLE receiver_admin (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    password_salt_base64 TEXT NOT NULL,
    password_hash_base64 TEXT NOT NULL,
    password_algorithm TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE admin_sessions (
    session_hash TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);

CREATE INDEX idx_admin_sessions_expires
    ON admin_sessions(expires_at);

CREATE TABLE pairing_sessions (
    session_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    code_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    revoked_at TEXT,
    paired_device_id TEXT,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (owner_id) REFERENCES owners(owner_id)
);

CREATE INDEX idx_pairing_sessions_active
    ON pairing_sessions(expires_at, consumed_at, revoked_at);
