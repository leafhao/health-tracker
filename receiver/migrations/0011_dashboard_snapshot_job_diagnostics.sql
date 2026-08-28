ALTER TABLE dashboard_snapshot_jobs
    ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;

ALTER TABLE dashboard_snapshot_jobs
    ADD COLUMN last_attempt_at TEXT;

ALTER TABLE dashboard_snapshot_jobs
    ADD COLUMN last_error TEXT;
