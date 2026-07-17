-- Per-meeting summary provenance: which LLM provider + model produced the
-- summary. Mirrors the transcription provenance columns
-- (20260714170000_add_transcription_provenance.sql). Populated on summary
-- completion; NULL for meetings summarized before this migration.
ALTER TABLE meetings ADD COLUMN summary_provider TEXT;
ALTER TABLE meetings ADD COLUMN summary_model TEXT;
