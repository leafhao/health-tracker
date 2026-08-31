-- Body composition is useful only when the underlying measurement is recent.
-- Remove values that older projections carried forward indefinitely, then mark
-- existing dashboard snapshots stale so the worker rebuilds only affected days.
CREATE TEMP TABLE stale_body_projection_dates (
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    PRIMARY KEY (timezone, date)
);

INSERT INTO stale_body_projection_dates(timezone, date)
SELECT timezone, date
FROM normalized_daily_summaries
WHERE (body_mass_at IS NOT NULL AND julianday(date) - julianday(date(body_mass_at)) > 30)
   OR (body_fat_at IS NOT NULL AND julianday(date) - julianday(date(body_fat_at)) > 30)
   OR (body_mass_index_at IS NOT NULL AND julianday(date) - julianday(date(body_mass_index_at)) > 30)
   OR (lean_body_mass_at IS NOT NULL AND julianday(date) - julianday(date(lean_body_mass_at)) > 30);

UPDATE normalized_daily_summaries
SET body_mass_kg = NULL, body_mass_at = NULL
WHERE body_mass_at IS NOT NULL
  AND julianday(date) - julianday(date(body_mass_at)) > 30;

UPDATE normalized_daily_summaries
SET body_fat_percent = NULL, body_fat_at = NULL
WHERE body_fat_at IS NOT NULL
  AND julianday(date) - julianday(date(body_fat_at)) > 30;

UPDATE normalized_daily_summaries
SET body_mass_index = NULL,
    body_mass_index_at = NULL,
    body_mass_index_source = NULL
WHERE body_mass_index_at IS NOT NULL
  AND julianday(date) - julianday(date(body_mass_index_at)) > 30;

UPDATE normalized_daily_summaries
SET lean_body_mass_kg = NULL,
    lean_body_mass_at = NULL,
    lean_body_mass_source = NULL
WHERE lean_body_mass_at IS NOT NULL
  AND julianday(date) - julianday(date(lean_body_mass_at)) > 30;

UPDATE normalized_daily_summaries
SET normalized_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE EXISTS (
    SELECT 1 FROM stale_body_projection_dates AS stale
    WHERE stale.timezone = normalized_daily_summaries.timezone
      AND stale.date = normalized_daily_summaries.date
);

UPDATE normalization_runs
SET normalized_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE EXISTS (
    SELECT 1 FROM stale_body_projection_dates AS stale
    WHERE stale.timezone = normalization_runs.timezone
      AND stale.date = normalization_runs.date
);

INSERT INTO dashboard_snapshot_jobs(
    timezone, date, reason, created_at, attempts, last_attempt_at, last_error
)
SELECT stale.timezone,
       stale.date,
       'expire stale body composition projection',
       strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
       0, NULL, NULL
FROM stale_body_projection_dates AS stale
JOIN dashboard_day_snapshots AS snapshots
  ON snapshots.timezone = stale.timezone AND snapshots.date = stale.date
ON CONFLICT(timezone, date) DO UPDATE SET
    reason = excluded.reason,
    created_at = excluded.created_at,
    attempts = 0,
    last_attempt_at = NULL,
    last_error = NULL;

DROP TABLE stale_body_projection_dates;
