ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleep_continuity REAL;

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleep_efficiency_basis TEXT;

ALTER TABLE normalized_workouts
    ADD COLUMN heart_rate_zones_json TEXT NOT NULL DEFAULT '{}';

ALTER TABLE normalized_workouts
    ADD COLUMN heart_rate_zone_method TEXT;
