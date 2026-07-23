-- Bugfix: an auto-match window-overlap bug (fixed in application code, see
-- find_closest_meeting_in_window/run_auto_match) allowed more than one calendar_events
-- row to point at the same meeting_id. A meeting must only ever be linked to at most one
-- calendar event. This migration heals any existing duplicates, then adds a partial
-- UNIQUE index so the DB itself rejects future duplicates regardless of code path
-- (auto-match or manual link).

-- For every meeting_id linked from more than one event, keep exactly one link: prefer an
-- existing manual link (an explicit user action) over an auto link, then break ties by
-- picking the event whose start_time is closest to the meeting's created_at (matching
-- get_event_by_meeting_id's tie-break) and finally by id for full determinism. Unlink
-- every other event pointing at that meeting.
WITH ranked AS (
    SELECT
        ce.id AS event_id,
        ROW_NUMBER() OVER (
            PARTITION BY ce.meeting_id
            ORDER BY
                CASE WHEN ce.link_source = 'manual' THEN 0 ELSE 1 END ASC,
                ABS(CAST((julianday(ce.start_time) - julianday(m.created_at)) * 86400.0 AS INTEGER)) ASC,
                ce.id ASC
        ) AS rn
    FROM calendar_events ce
    JOIN meetings m ON m.id = ce.meeting_id
    WHERE ce.meeting_id IS NOT NULL
)
UPDATE calendar_events
SET meeting_id = NULL, link_source = NULL
WHERE id IN (SELECT event_id FROM ranked WHERE rn > 1);

DROP INDEX IF EXISTS idx_calendar_events_meeting;
CREATE UNIQUE INDEX IF NOT EXISTS idx_calendar_events_meeting_unique
    ON calendar_events(meeting_id) WHERE meeting_id IS NOT NULL;
