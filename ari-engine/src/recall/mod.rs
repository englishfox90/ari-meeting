//! Recall (F7): semantic + lexical retrieval over saved meeting transcripts, plus the
//! index that powers it, plus the "Ask Meetings" safety shell (`shell`) — moved into
//! `ari-engine` during the ari-engine carve (Stage B1, `docs/plans/ari-engine-carve.md`).
//! The host keeps only `#[tauri::command]` shims calling into this module; every
//! bounding/prompt/source-safety invariant enforced by `local_recall_tests` lives here
//! now, unchanged.
//!
//! Layers:
//! - `shell`     — the recall safety shell: gating, prompt assembly, bounding, and the
//!                 single-shot `api_answer_meetings_locally_impl` (formerly in `api/api.rs`).
//! - `chunker`   — split a meeting's transcript into overlapping windows.
//! - `embedding` — f32<->BLOB packing, cosine, and the embedder dispatch.
//! - `indexer`   — build/refresh the per-meeting index (idempotent, best-effort embeds).
//! - `search`    — hybrid BM25 ⊕ vector retrieval with recency weighting.
//! - `agent`     — the agentic Claude tool-use path.
//! - `context`   — people/calendar context enrichment for the prompt.
//! - `citations` — inline citation + @ref(MM:SS) verification (no invented citations).
//! - `commands`, `conversations`, `stream`, `embed_models` — `_impl` fns behind the
//!   host's `#[tauri::command]` shims.

pub mod agent;
pub mod chunker;
pub mod citations;
pub mod commands;
pub mod context;
pub mod conversations;
pub mod embed_apple;
pub mod embed_models;
pub mod embed_runtime;
pub mod embed_sidecar;
pub mod embedding;
pub mod indexer;
pub mod search;
pub mod shell;
pub mod stream;

pub use indexer::index_meeting;
pub use shell::{
    api_answer_meetings_locally_impl, build_global_recall_sources, build_local_recall_context,
    build_local_recall_history, build_meeting_recall_sources, is_loopback_ollama_endpoint,
    is_unsupported_recall_question, recall_system_prompt, summary_markdown, LocalRecallResponse,
    LocalRecallSource, LocalRecallTurn,
};
