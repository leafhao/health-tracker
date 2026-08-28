ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleeping_heart_rate_avg_bpm REAL;

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleeping_heart_rate_min_bpm REAL;

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleeping_heart_rate_max_bpm REAL;

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleeping_hrv_sdnn_ms REAL;

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleeping_respiratory_rate REAL;

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleeping_oxygen_avg_percent REAL;

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleeping_oxygen_min_percent REAL;

ALTER TABLE normalized_sleep_summaries
    ADD COLUMN sleeping_wrist_temperature_c REAL;

CREATE TABLE normalized_training_summaries (
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    workout_count INTEGER NOT NULL,
    workout_minutes REAL NOT NULL,
    energy_kcal REAL NOT NULL,
    heart_rate_covered_minutes REAL NOT NULL,
    zone_1_minutes REAL NOT NULL,
    zone_2_minutes REAL NOT NULL,
    zone_3_minutes REAL NOT NULL,
    zone_4_minutes REAL NOT NULL,
    zone_5_minutes REAL NOT NULL,
    high_intensity_minutes REAL NOT NULL,
    load_score REAL NOT NULL,
    normalized_at TEXT NOT NULL,
    PRIMARY KEY (timezone, date)
);

CREATE TABLE device_capabilities (
    device_id TEXT PRIMARY KEY,
    app_version TEXT,
    platform_version TEXT,
    health_data_available INTEGER NOT NULL,
    health_permissions_requested INTEGER NOT NULL,
    supported_quantity_types_json TEXT NOT NULL,
    supported_domains_json TEXT NOT NULL,
    reported_at TEXT NOT NULL,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
