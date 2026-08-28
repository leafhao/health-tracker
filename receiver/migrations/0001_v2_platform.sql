CREATE TABLE owners (
    owner_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE receiver_keys (
    key_id TEXT PRIMARY KEY,
    algorithm TEXT NOT NULL,
    public_key_base64 TEXT NOT NULL,
    key_file TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
);

CREATE TABLE devices (
    owner_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    signing_key_id TEXT NOT NULL,
    signing_public_key_base64 TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    last_sequence INTEGER NOT NULL DEFAULT 0,
    last_seen_at TEXT,
    created_at TEXT NOT NULL,
    PRIMARY KEY (owner_id, device_id),
    UNIQUE (owner_id, signing_key_id),
    FOREIGN KEY (owner_id) REFERENCES owners(owner_id)
);

CREATE UNIQUE INDEX idx_devices_global_device_id ON devices(device_id);

CREATE TABLE ingest_batches (
    owner_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    stream_id TEXT NOT NULL,
    previous_batch_id TEXT,
    object_key TEXT,
    envelope_sha256 TEXT NOT NULL,
    status TEXT NOT NULL,
    event_count INTEGER NOT NULL DEFAULT 0,
    accepted_count INTEGER NOT NULL DEFAULT 0,
    rejected_count INTEGER NOT NULL DEFAULT 0,
    gap_detected INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    committed_at TEXT,
    error_message TEXT,
    PRIMARY KEY (owner_id, device_id, batch_id),
    UNIQUE (owner_id, device_id, sequence),
    FOREIGN KEY (owner_id, device_id) REFERENCES devices(owner_id, device_id)
);

CREATE INDEX idx_ingest_batches_status
    ON ingest_batches(status, created_at);

CREATE TABLE raw_events (
    event_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    stream_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    operation TEXT NOT NULL CHECK(operation IN ('upsert', 'delete')),
    entity_type TEXT NOT NULL,
    source_uuid TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    payload_json TEXT,
    ingested_at TEXT NOT NULL,
    FOREIGN KEY (owner_id, device_id, batch_id)
        REFERENCES ingest_batches(owner_id, device_id, batch_id)
);

CREATE INDEX idx_raw_events_source
    ON raw_events(owner_id, entity_type, source_uuid, observed_at);

CREATE TABLE tombstones (
    owner_id TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    source_uuid TEXT NOT NULL,
    event_id TEXT NOT NULL,
    deleted_at TEXT NOT NULL,
    device_id TEXT NOT NULL,
    PRIMARY KEY (owner_id, entity_type, source_uuid),
    FOREIGN KEY (event_id) REFERENCES raw_events(event_id)
);

CREATE TABLE normalization_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id TEXT NOT NULL,
    date TEXT NOT NULL,
    timezone TEXT NOT NULL,
    reason TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    error_message TEXT,
    UNIQUE (owner_id, date, timezone, status)
);

CREATE INDEX idx_normalization_jobs_pending
    ON normalization_jobs(status, created_at);

CREATE TABLE sync_receipts (
    owner_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    status TEXT NOT NULL,
    accepted INTEGER NOT NULL,
    rejected INTEGER NOT NULL,
    gap_detected INTEGER NOT NULL,
    committed_at TEXT NOT NULL,
    receipt_json TEXT NOT NULL,
    PRIMARY KEY (owner_id, device_id, batch_id),
    FOREIGN KEY (owner_id, device_id, batch_id)
        REFERENCES ingest_batches(owner_id, device_id, batch_id)
);

CREATE TABLE route_points (
    owner_id TEXT NOT NULL,
    route_uuid TEXT NOT NULL,
    workout_uuid TEXT NOT NULL,
    point_index INTEGER NOT NULL,
    timestamp TEXT NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    altitude REAL,
    horizontal_accuracy REAL,
    vertical_accuracy REAL,
    speed REAL,
    course REAL,
    PRIMARY KEY (owner_id, route_uuid, point_index)
);

CREATE INDEX idx_route_points_workout_time
    ON route_points(owner_id, workout_uuid, timestamp);
