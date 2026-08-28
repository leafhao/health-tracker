CREATE TABLE dashboard_global_snapshots (
    name TEXT PRIMARY KEY,
    payload_json TEXT NOT NULL,
    source_revision TEXT,
    materialized_at TEXT NOT NULL
);

CREATE TABLE dashboard_day_snapshots (
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    source_normalized_at TEXT NOT NULL,
    materialized_at TEXT NOT NULL,
    PRIMARY KEY (timezone, date)
);

CREATE TABLE dashboard_snapshot_jobs (
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (timezone, date)
);

CREATE INDEX idx_dashboard_snapshot_jobs_created
    ON dashboard_snapshot_jobs(created_at, timezone, date);

CREATE TABLE worker_heartbeats (
    worker_name TEXT PRIMARY KEY,
    pid INTEGER NOT NULL,
    status TEXT NOT NULL,
    last_heartbeat_at TEXT NOT NULL,
    last_success_at TEXT,
    last_error TEXT
);
