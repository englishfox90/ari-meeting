-- Recall semantic index + Ask conversation store (F7).
-- Additive-only: new tables + one FTS5 virtual table. No existing table is altered.

-- Per-chunk transcript index. `embedding` is opaque little-endian f32 bytes (matcher-owned),
-- mirroring the speakers.centroid BLOB convention. NULL embedding => lexical-only chunk
-- (Ollama embedder was unavailable at index time; re-indexing later fills it in).
CREATE TABLE IF NOT EXISTS recall_chunks (
    id              TEXT PRIMARY KEY,
    meeting_id      TEXT NOT NULL,
    chunk_index     INTEGER NOT NULL,
    chunk_text      TEXT NOT NULL,
    -- Recording-relative seconds spanned by this chunk (for timestamp citations).
    start_time      REAL,
    end_time        REAL,
    -- Display timestamp label for the chunk start, e.g. "12:05".
    timestamp_label TEXT,
    embedding       BLOB,
    embedding_model TEXT,
    dim             INTEGER,
    token_estimate  INTEGER,
    created_at      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_recall_chunks_meeting ON recall_chunks(meeting_id);

-- Per-meeting index bookkeeping so re-indexing is idempotent and status is queryable.
CREATE TABLE IF NOT EXISTS recall_index_state (
    meeting_id      TEXT PRIMARY KEY,
    content_hash    TEXT NOT NULL,
    chunk_count     INTEGER NOT NULL,
    embedding_model TEXT,
    embedded_count  INTEGER NOT NULL DEFAULT 0,
    indexed_at      TEXT NOT NULL
);

-- FTS5 lexical index over chunk text (BM25). Standalone (not external-content) for
-- robustness; chunk_id/meeting_id are UNINDEXED so matches map back without a join.
-- The recall repository keeps this table in lockstep with recall_chunks on write.
CREATE VIRTUAL TABLE IF NOT EXISTS recall_fts USING fts5(
    chunk_text,
    chunk_id UNINDEXED,
    meeting_id UNINDEXED,
    tokenize = 'porter unicode61'
);

-- Ask conversation persistence. `meeting_id` NULL => a global (dedicated-page) chat;
-- non-NULL => a meeting-scoped chat. Retention (last 7 days) is enforced in Rust by
-- pruning rows whose updated_at is older than the window.
CREATE TABLE IF NOT EXISTS ask_conversations (
    id          TEXT PRIMARY KEY,
    meeting_id  TEXT,
    title       TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ask_conversations_updated ON ask_conversations(updated_at);
CREATE INDEX IF NOT EXISTS idx_ask_conversations_meeting ON ask_conversations(meeting_id);

CREATE TABLE IF NOT EXISTS ask_messages (
    id              TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role            TEXT NOT NULL,
    content         TEXT NOT NULL,
    -- JSON array of the sources the app supplied for an assistant turn (never trusted
    -- from the model). NULL for user turns.
    sources_json    TEXT,
    created_at      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ask_messages_conversation ON ask_messages(conversation_id);
