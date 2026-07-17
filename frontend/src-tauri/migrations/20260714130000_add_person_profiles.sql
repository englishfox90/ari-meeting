-- Person Profiles (F2). Additive. Two tiers: authored identity (persons) + inferred facts
-- (profile_facts, append-only w/ supersession). Persons are seeded from calendar attendee
-- emails (F4). Owner is a person row with is_owner=1 (F3 reads it for summary context).

CREATE TABLE IF NOT EXISTS persons (
    id            TEXT PRIMARY KEY,               -- uuid v4
    email         TEXT,                           -- natural key; matches calendar attendee email; NULL allowed
    display_name  TEXT NOT NULL,
    role          TEXT,                           -- authored: job title / role
    organization  TEXT,                           -- authored: who they work for
    domain        TEXT,                           -- authored: what they do / area of focus
    notes         TEXT,                           -- freeform authored notes
    is_owner      INTEGER NOT NULL DEFAULT 0,     -- exactly 0 or 1 rows should be 1
    created_at    TEXT NOT NULL,                  -- RFC3339 UTC
    updated_at    TEXT NOT NULL
);
-- one person per non-null email
CREATE UNIQUE INDEX IF NOT EXISTS idx_persons_email ON persons(email) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_persons_owner ON persons(is_owner);

CREATE TABLE IF NOT EXISTS profile_facts (
    id                 TEXT PRIMARY KEY,          -- uuid v4
    person_id          TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
    fact_text          TEXT NOT NULL,
    fact_kind          TEXT NOT NULL DEFAULT 'other',  -- 'goal'|'interest'|'project'|'role_signal'|'other'
    source_meeting_id  TEXT REFERENCES meetings(id) ON DELETE SET NULL,
    source_segment_ref TEXT,                      -- evidence quote or time range; nullable
    source_kind        TEXT NOT NULL DEFAULT 'attributed', -- 'self_reported'|'attributed'
    confidence         REAL NOT NULL DEFAULT 0.0, -- 0.0..1.0
    status             TEXT NOT NULL DEFAULT 'pending', -- 'pending'|'active'|'superseded'|'rejected'
    superseded_by      TEXT REFERENCES profile_facts(id) ON DELETE SET NULL,
    created_at         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_profile_facts_person ON profile_facts(person_id);
CREATE INDEX IF NOT EXISTS idx_profile_facts_status ON profile_facts(status);
CREATE INDEX IF NOT EXISTS idx_profile_facts_meeting ON profile_facts(source_meeting_id);

CREATE TABLE IF NOT EXISTS meeting_participants (
    meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    person_id   TEXT NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
    link_source TEXT NOT NULL,                    -- 'calendar'|'manual'|'speaker'(future F1)
    created_at  TEXT NOT NULL,
    PRIMARY KEY (meeting_id, person_id)
);
CREATE INDEX IF NOT EXISTS idx_meeting_participants_person ON meeting_participants(person_id);
