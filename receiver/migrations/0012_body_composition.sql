ALTER TABLE normalized_daily_summaries
    ADD COLUMN body_fat_percent REAL;

ALTER TABLE normalized_daily_summaries
    ADD COLUMN body_fat_at TEXT;

ALTER TABLE normalized_daily_summaries
    ADD COLUMN body_mass_index REAL;

ALTER TABLE normalized_daily_summaries
    ADD COLUMN body_mass_index_at TEXT;

ALTER TABLE normalized_daily_summaries
    ADD COLUMN body_mass_index_source TEXT;

ALTER TABLE normalized_daily_summaries
    ADD COLUMN lean_body_mass_kg REAL;

ALTER TABLE normalized_daily_summaries
    ADD COLUMN lean_body_mass_at TEXT;

ALTER TABLE normalized_daily_summaries
    ADD COLUMN lean_body_mass_source TEXT;
