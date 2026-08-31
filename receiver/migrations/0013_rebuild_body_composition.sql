-- Existing raw body samples predate the body-composition projection. Rebuild
-- only their actual measurement dates; the worker refreshes dashboard snapshots.
INSERT INTO normalization_jobs(
    owner_id, date, timezone, reason, status, attempts, created_at,
    started_at, completed_at, error_message
)
SELECT COALESCE((SELECT owner_id FROM owners ORDER BY created_at LIMIT 1), 'local'),
       date(datetime(start_date, '+8 hours')),
       'Asia/Shanghai',
       'body composition projection upgrade',
       'pending', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), NULL, NULL, NULL
FROM quantity_samples
WHERE type IN (
    'HKQuantityTypeIdentifierBodyMass',
    'HKQuantityTypeIdentifierBodyFatPercentage',
    'HKQuantityTypeIdentifierBodyMassIndex',
    'HKQuantityTypeIdentifierLeanBodyMass',
    'HKQuantityTypeIdentifierHeight'
)
GROUP BY date(datetime(start_date, '+8 hours'))
ON CONFLICT(owner_id, date, timezone) DO UPDATE SET
    reason=excluded.reason,
    status='pending',
    attempts=0,
    created_at=excluded.created_at,
    started_at=NULL,
    completed_at=NULL,
    error_message=NULL;
