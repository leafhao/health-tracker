ALTER TABLE normalization_jobs RENAME TO normalization_jobs_v2_old;

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
    UNIQUE (owner_id, date, timezone)
);

INSERT INTO normalization_jobs(
    owner_id, date, timezone, reason, status, attempts,
    created_at, started_at, completed_at, error_message
)
SELECT owner_id,
       date,
       timezone,
       'coalesced migration',
       CASE
           WHEN MAX(CASE WHEN status IN ('pending', 'running') THEN 1 ELSE 0 END) = 1
               THEN 'pending'
           WHEN MAX(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) = 1
               THEN 'completed'
           ELSE 'failed'
       END,
       0,
       MAX(created_at),
       NULL,
       MAX(completed_at),
       NULL
FROM normalization_jobs_v2_old
GROUP BY owner_id, date, timezone;

DROP TABLE normalization_jobs_v2_old;

CREATE INDEX idx_normalization_jobs_pending
    ON normalization_jobs(status, created_at);

CREATE INDEX idx_quantity_overlap
    ON quantity_samples(start_date, end_date);

CREATE INDEX idx_category_type_overlap
    ON category_samples(type, start_date, end_date);

CREATE INDEX idx_ingest_batches_committed_at
    ON ingest_batches(committed_at);

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN segments_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE normalized_workouts
    ADD COLUMN route_preview_json TEXT NOT NULL DEFAULT '[]';
