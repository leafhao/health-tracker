CREATE TABLE cloud_relay_objects (
    device_id TEXT NOT NULL,
    object_key TEXT NOT NULL,
    pack_id TEXT,
    receipt_key TEXT,
    status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    first_seen_at TEXT NOT NULL,
    processed_at TEXT,
    delete_after TEXT,
    deleted_at TEXT,
    error_message TEXT,
    PRIMARY KEY (device_id, object_key)
);

CREATE INDEX idx_cloud_relay_cleanup
    ON cloud_relay_objects(status, delete_after);
