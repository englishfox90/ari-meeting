-- Speaker Diarization (F1). Additive. Persistent voiceprints (speakers) + per-meeting
-- diarized segments (speaker_segments). A speaker is a voice centroid that may be linked to
-- a person (F2) once confirmed. Segments record where a cluster spoke within a meeting and
-- carry the raw embedding for later re-clustering / folding into a centroid.
-- The matcher (pure fn, separate module) owns the f32 interpretation of centroid/embedding
-- BLOBs; this schema treats them as opaque bytes.

CREATE TABLE IF NOT EXISTS speakers (
    id               TEXT PRIMARY KEY,                 -- uuid v4
    person_id        TEXT REFERENCES persons(id) ON DELETE SET NULL, -- linked person once confirmed; NULL = unassigned
    label            TEXT,                             -- optional human label (e.g. "Speaker 2")
    centroid         BLOB NOT NULL,                    -- opaque voiceprint bytes (f32 vector, matcher-owned)
    embedding_model  TEXT NOT NULL,                    -- model id that produced the centroid
    dim              INTEGER NOT NULL,                 -- centroid dimensionality
    samples          INTEGER NOT NULL DEFAULT 1,       -- how many segments folded into the centroid
    enrollment_state TEXT NOT NULL DEFAULT 'provisional', -- 'provisional'|'confirmed'
    created_at       TEXT NOT NULL,                    -- RFC3339 UTC
    updated_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_speakers_person ON speakers(person_id);

CREATE TABLE IF NOT EXISTS speaker_segments (
    id          TEXT PRIMARY KEY,                      -- uuid v4
    meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    speaker_id  TEXT REFERENCES speakers(id) ON DELETE SET NULL, -- resolved speaker; NULL until matched
    cluster_key TEXT NOT NULL,                         -- within-meeting cluster label (pre-identity)
    start_time  REAL NOT NULL,                         -- recording-relative seconds
    end_time    REAL NOT NULL,
    source      TEXT NOT NULL,                         -- 'microphone'|'system'
    embedding   BLOB,                                  -- opaque per-segment embedding bytes; nullable
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_speaker_segments_meeting ON speaker_segments(meeting_id);

-- New per-transcript speaker link. Distinct from the dead `speaker` column (mic/system labels
-- from 20251110000001). FK intent: REFERENCES speakers(id) — SQLite cannot add an enforced FK
-- via ALTER TABLE ADD COLUMN, so this is a plain column carrying that reference by convention.
ALTER TABLE transcripts ADD COLUMN speaker_id TEXT;
