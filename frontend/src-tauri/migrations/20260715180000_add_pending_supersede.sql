-- Person Profiles (F2) — deferred supersession. Additive.
--
-- Previously, when reconciliation decided an existing ACTIVE fact was outdated, it
-- immediately marked that fact 'superseded' and inserted the replacement as 'pending'.
-- Net effect: the fact dropped out of the active set (and out of summary context) until
-- the user confirmed the replacement — an update silently deleted the old fact first.
--
-- New model: the replacement is inserted 'pending' with `supersedes_fact_id` pointing at
-- the fact it will replace. The old fact stays ACTIVE and keeps being used until the user
-- CONFIRMS the pending replacement, at which point the old one is retired ('superseded').
-- Rejecting the pending replacement leaves the old fact untouched.
ALTER TABLE profile_facts ADD COLUMN supersedes_fact_id TEXT REFERENCES profile_facts(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_profile_facts_supersedes ON profile_facts(supersedes_fact_id);
