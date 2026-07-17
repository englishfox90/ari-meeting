-- Meeting Series (F9). Additive. Groups recurring meetings (calendar recurrence or heuristic)
-- into a series, with a rolling per-series ledger. Does NOT touch the upstream `meetings`
-- table. Extends the Ari-authored `calendar_events` (F4) with recurrence signals used to
-- derive a stable series_key (EventKit calendarItemExternalIdentifier).

-- Recurrence signals on calendar_events (F4, Ari-authored). One ALTER per column (sqlite).
ALTER TABLE calendar_events ADD COLUMN series_key TEXT;
ALTER TABLE calendar_events ADD COLUMN has_recurrence INTEGER DEFAULT 0;
ALTER TABLE calendar_events ADD COLUMN occurrence_date TEXT;
ALTER TABLE calendar_events ADD COLUMN is_detached INTEGER DEFAULT 0;

CREATE TABLE IF NOT EXISTS meeting_series (
    id              TEXT PRIMARY KEY,               -- uuid v4
    series_key      TEXT,                           -- calendar calendarItemExternalIdentifier; NULL for heuristic series
    title           TEXT NOT NULL,
    detected_type   TEXT,                           -- e.g. '1:1'|'standup'; nullable
    cadence         TEXT,                           -- e.g. 'weekly'|'biweekly'; nullable
    owner_person_id TEXT REFERENCES persons(id) ON DELETE SET NULL,
    created_at      TEXT NOT NULL,                  -- RFC3339 UTC
    updated_at      TEXT NOT NULL
);
-- one series per non-null series_key
CREATE UNIQUE INDEX IF NOT EXISTS idx_meeting_series_key ON meeting_series(series_key) WHERE series_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS meeting_series_members (
    series_id       TEXT NOT NULL REFERENCES meeting_series(id) ON DELETE CASCADE,
    meeting_id      TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    occurrence_time TEXT,                           -- RFC3339 UTC of this occurrence; nullable
    link_source     TEXT,                           -- 'auto' | 'manual'
    created_at      TEXT NOT NULL,
    PRIMARY KEY (series_id, meeting_id)
);
CREATE INDEX IF NOT EXISTS idx_meeting_series_members_meeting ON meeting_series_members(meeting_id);

CREATE TABLE IF NOT EXISTS series_ledger (
    series_id               TEXT PRIMARY KEY REFERENCES meeting_series(id) ON DELETE CASCADE,
    ledger_markdown         TEXT,
    structured_json         TEXT,
    updated_from_meeting_id TEXT REFERENCES meetings(id) ON DELETE SET NULL,
    version                 INTEGER NOT NULL DEFAULT 0,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL
);
