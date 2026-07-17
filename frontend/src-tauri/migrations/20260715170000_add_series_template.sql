-- Meeting Series (F9) — template inheritance. Additive.
-- Remembers the summary template a series settled on, so the first meeting classifies
-- it (via the LLM) and subsequent occurrences INHERIT it instead of re-classifying —
-- more consistent output and one fewer LLM call per meeting.
ALTER TABLE meeting_series ADD COLUMN template_id TEXT;
