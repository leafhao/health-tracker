ALTER TABLE normalization_jobs RENAME TO normalization_jobs_v1;

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
    error_message TEXT
);

INSERT INTO normalization_jobs(
    id, owner_id, date, timezone, reason, status, attempts,
    created_at, started_at, completed_at, error_message
)
SELECT id, owner_id, date, timezone, reason, status, attempts,
       created_at, started_at, completed_at, error_message
FROM normalization_jobs_v1;

DROP TABLE normalization_jobs_v1;

CREATE INDEX idx_normalization_jobs_pending
    ON normalization_jobs(status, created_at);

CREATE UNIQUE INDEX idx_normalization_jobs_one_active
    ON normalization_jobs(owner_id, date, timezone)
    WHERE status IN ('pending', 'running');
