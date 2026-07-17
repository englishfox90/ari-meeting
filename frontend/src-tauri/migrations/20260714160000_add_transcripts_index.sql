-- Speeds up per-meeting transcript pagination (WHERE meeting_id + ORDER BY audio_start_time).
-- transcripts had no index at all; opening large meetings did a full table scan + temp b-tree sort.
CREATE INDEX IF NOT EXISTS idx_transcripts_meeting_time ON transcripts(meeting_id, audio_start_time);
