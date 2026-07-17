-- Person Profiles (F2) — multi-source facts. Additive.
--
-- Previously a `profile_fact` carried exactly ONE source (`source_meeting_id` +
-- `source_segment_ref`): whichever meeting last produced/superseded it. When a fact was
-- superseded, the replacement started from a single new source and the prior meeting's
-- evidence was lost. That is wrong — a durable fact is corroborated by MANY meetings, and
-- superseding should BRING THOSE SOURCES TOGETHER rather than keep only the latest, in case
-- detail from the older observation didn't survive into the newer one.
--
-- New model: a fact accumulates rows in `profile_fact_sources`, one per observation:
--   - relation 'origin'     — the meeting/evidence that first produced this fact row
--   - relation 'reaffirmed' — a later meeting that reconciliation decided to KEEP the fact on
--   - relation 'carried'    — a source inherited from a fact this one superseded (lineage)
-- Each source keeps its own meeting, evidence quote, source_kind, confidence, and observed_at,
-- so provenance is never collapsed to "the latest single meeting". `profile_facts` keeps its
-- own `source_meeting_id`/`confidence` columns untouched (backward compatible); the sources
-- table is the fuller record. `source_count` for a fact is COUNT(*) over this table.
--
-- No-Fake-State: manually-added facts (no meeting) get NO source row — sourceCount 0, honest.

CREATE TABLE IF NOT EXISTS profile_fact_sources (
    id           TEXT PRIMARY KEY,                                          -- uuid v4
    fact_id      TEXT NOT NULL REFERENCES profile_facts(id) ON DELETE CASCADE,
    meeting_id   TEXT REFERENCES meetings(id) ON DELETE SET NULL,           -- nullable (manual/unknown)
    segment_ref  TEXT,                                                      -- evidence quote / time range
    source_kind  TEXT NOT NULL DEFAULT 'attributed',                        -- 'self_reported'|'attributed'
    relation     TEXT NOT NULL DEFAULT 'origin',                            -- 'origin'|'reaffirmed'|'carried'
    confidence   REAL NOT NULL DEFAULT 0.0,                                 -- 0.0..1.0 at time of observation
    observed_at  TEXT NOT NULL                                              -- RFC3339 UTC
);
CREATE INDEX IF NOT EXISTS idx_profile_fact_sources_fact ON profile_fact_sources(fact_id);
CREATE INDEX IF NOT EXISTS idx_profile_fact_sources_meeting ON profile_fact_sources(meeting_id);

-- Backfill: give every existing meeting-derived fact an 'origin' source mirroring its current
-- single-source columns, so historical facts show a truthful sourceCount of at least 1. Facts
-- with no source_meeting_id (manually added) are intentionally left with zero sources.
INSERT INTO profile_fact_sources (id, fact_id, meeting_id, segment_ref, source_kind, relation, confidence, observed_at)
SELECT
    lower(hex(randomblob(16))),
    pf.id,
    pf.source_meeting_id,
    pf.source_segment_ref,
    pf.source_kind,
    'origin',
    pf.confidence,
    pf.created_at
FROM profile_facts pf
WHERE pf.source_meeting_id IS NOT NULL;
