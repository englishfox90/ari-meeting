-- Per-meeting summary template: which template (e.g. "one_on_one",
-- "standard_meeting") produced the meeting's summary. Populated on summary
-- completion so the Template picker in meeting details can reflect the template
-- that was actually used (including F6 auto-suggested ones) instead of always
-- defaulting to "standard_meeting". NULL for meetings summarized before this
-- migration — those are backfilled at read time from the template_id already
-- embedded in the summary_processes.result cache blob.
ALTER TABLE meetings ADD COLUMN template_id TEXT;
