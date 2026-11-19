-- Once, on the database made with the first schema (2026-11-19): columns schema.sql has now.
ALTER TABLE device_tokens ADD COLUMN verified INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channels ADD COLUMN tries INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channels ADD COLUMN next_try INTEGER;
