PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS quantity_samples (
    uuid TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    value REAL NOT NULL,
    unit TEXT,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    source_name TEXT,
    source_bundle_id TEXT,
    device_name TEXT,
    metadata TEXT,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_quantity_type_start
    ON quantity_samples(type, start_date);

CREATE TABLE IF NOT EXISTS category_samples (
    uuid TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    value INTEGER NOT NULL,
    value_label TEXT,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    source_name TEXT,
    source_bundle_id TEXT,
    device_name TEXT,
    metadata TEXT,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_category_type_start
    ON category_samples(type, start_date);

CREATE TABLE IF NOT EXISTS workouts (
    uuid TEXT PRIMARY KEY,
    activity_type TEXT NOT NULL,
    duration_seconds REAL NOT NULL,
    total_energy_burned_kcal REAL,
    total_distance_meters REAL,
    total_swimming_strokes REAL,
    total_flights_climbed REAL,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    source_name TEXT,
    source_bundle_id TEXT,
    device_name TEXT,
    metadata TEXT,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_workouts_start
    ON workouts(start_date);

CREATE TABLE IF NOT EXISTS workout_routes (
    uuid TEXT PRIMARY KEY,
    workout_uuid TEXT NOT NULL,
    start_date TEXT NOT NULL,
    location_count INTEGER NOT NULL,
    locations_json TEXT,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (workout_uuid) REFERENCES workouts(uuid) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_routes_workout
    ON workout_routes(workout_uuid);

CREATE TABLE IF NOT EXISTS activity_summaries (
    date TEXT PRIMARY KEY,
    active_energy_burned REAL,
    active_energy_burned_goal REAL,
    exercise_time_minutes REAL,
    exercise_time_goal_minutes REAL,
    stand_hours INTEGER,
    stand_hours_goal INTEGER,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS ingest_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    endpoint TEXT NOT NULL,
    accepted INTEGER NOT NULL,
    rejected INTEGER NOT NULL,
    remote_address TEXT,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- Raw HealthKit rows above are intentionally immutable-by-UUID staging data.
-- The tables below are deterministic, rebuildable projections used by daily
-- exports and the dashboard. Keeping both layers prevents a normalization bug
-- from permanently discarding source records.
CREATE TABLE IF NOT EXISTS normalized_quantity_minutes (
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    minute TEXT NOT NULL,
    type TEXT NOT NULL,
    value REAL NOT NULL,
    min_value REAL,
    max_value REAL,
    sample_count INTEGER NOT NULL,
    unit TEXT,
    source_name TEXT,
    source_rank INTEGER NOT NULL,
    normalized_at TEXT NOT NULL,
    PRIMARY KEY (timezone, minute, type)
);

CREATE INDEX IF NOT EXISTS idx_normalized_quantity_day_type
    ON normalized_quantity_minutes(timezone, date, type, minute);

CREATE TABLE IF NOT EXISTS normalized_daily_summaries (
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    steps REAL,
    walking_running_distance_m REAL,
    cycling_distance_m REAL,
    active_energy_kcal REAL,
    basal_energy_kcal REAL,
    flights_climbed REAL,
    exercise_minutes REAL,
    stand_hours REAL,
    resting_heart_rate_bpm REAL,
    walking_heart_rate_bpm REAL,
    hrv_sdnn_ms REAL,
    respiratory_rate REAL,
    oxygen_saturation_percent REAL,
    vo2_max REAL,
    vo2_max_at TEXT,
    heart_rate_recovery_bpm REAL,
    heart_rate_recovery_at TEXT,
    body_mass_kg REAL,
    body_mass_at TEXT,
    normalized_at TEXT NOT NULL,
    PRIMARY KEY (timezone, date)
);

CREATE TABLE IF NOT EXISTS normalized_sleep_summaries (
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    window_start TEXT NOT NULL,
    window_end TEXT NOT NULL,
    main_sleep_start TEXT,
    main_sleep_end TEXT,
    total_asleep_minutes REAL NOT NULL,
    main_sleep_minutes REAL NOT NULL,
    nap_minutes REAL NOT NULL,
    core_minutes REAL NOT NULL,
    deep_minutes REAL NOT NULL,
    rem_minutes REAL NOT NULL,
    unspecified_minutes REAL NOT NULL,
    awake_minutes REAL NOT NULL,
    in_bed_minutes REAL,
    sleep_efficiency REAL,
    session_count INTEGER NOT NULL,
    sources_json TEXT NOT NULL,
    normalized_at TEXT NOT NULL,
    PRIMARY KEY (timezone, date)
);

CREATE TABLE IF NOT EXISTS normalized_workouts (
    uuid TEXT PRIMARY KEY,
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    activity_type TEXT NOT NULL,
    start_date TEXT NOT NULL,
    end_date TEXT NOT NULL,
    duration_seconds REAL NOT NULL,
    energy_kcal REAL,
    distance_meters REAL,
    pace_seconds_per_km REAL,
    flights_climbed REAL,
    elevation_gain_meters REAL,
    route_points INTEGER NOT NULL,
    heart_rate_samples INTEGER NOT NULL,
    heart_rate_avg_bpm REAL,
    heart_rate_min_bpm REAL,
    heart_rate_max_bpm REAL,
    cadence_steps_per_minute REAL,
    running_power_watts REAL,
    running_speed_meters_per_second REAL,
    running_stride_length_meters REAL,
    running_vertical_oscillation_cm REAL,
    running_ground_contact_time_ms REAL,
    source_name TEXT,
    normalized_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_normalized_workouts_day
    ON normalized_workouts(timezone, date, start_date);

CREATE TABLE IF NOT EXISTS normalization_runs (
    timezone TEXT NOT NULL,
    date TEXT NOT NULL,
    raw_quantity_count INTEGER NOT NULL,
    raw_sleep_count INTEGER NOT NULL,
    raw_workout_count INTEGER NOT NULL,
    normalized_at TEXT NOT NULL,
    PRIMARY KEY (timezone, date)
);
