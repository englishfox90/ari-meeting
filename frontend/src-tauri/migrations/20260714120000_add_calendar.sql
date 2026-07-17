-- Calendar feature (F4): EventKit-sourced calendar events + per-calendar sync selection.
-- Additive-only: does not touch the upstream `meetings` table. Links are via
-- calendar_events.meeting_id (nullable FK, ON DELETE SET NULL).

CREATE TABLE IF NOT EXISTS calendar_events (
    id            TEXT PRIMARY KEY,          -- EventKit eventIdentifier
    calendar_id   TEXT NOT NULL,             -- EventKit calendar identifier
    calendar_title TEXT,
    title         TEXT NOT NULL,
    start_time    TEXT NOT NULL,             -- ISO 8601 UTC
    end_time      TEXT NOT NULL,             -- ISO 8601 UTC
    is_all_day    INTEGER NOT NULL DEFAULT 0,
    location      TEXT,
    notes         TEXT,
    organizer     TEXT,
    attendees     TEXT,                      -- JSON array: [{"name":..,"email":..}]
    synced_at     TEXT NOT NULL,
    meeting_id    TEXT REFERENCES meetings(id) ON DELETE SET NULL,
    link_source   TEXT                       -- 'auto' | 'manual' | NULL
);
CREATE INDEX IF NOT EXISTS idx_calendar_events_start ON calendar_events(start_time);
CREATE INDEX IF NOT EXISTS idx_calendar_events_meeting ON calendar_events(meeting_id);

CREATE TABLE IF NOT EXISTS calendar_sync_settings (
    calendar_id    TEXT PRIMARY KEY,
    calendar_title TEXT,
    color          TEXT,
    selected       INTEGER NOT NULL DEFAULT 0
);
