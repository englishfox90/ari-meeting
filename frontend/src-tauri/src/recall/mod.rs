//! Recall (F7): semantic + lexical retrieval over saved meeting transcripts, plus the
//! index that powers it. Additive-only — attaches to the existing "Ask Meetings" command
//! by swapping just its global retrieval call; all bounding/prompt/source-safety logic in
//! `api/api.rs` is untouched.
//!
//! Layers:
//! - `chunker`   — split a meeting's transcript into overlapping windows.
//! - `embedding` — f32<->BLOB packing, cosine, and the Ollama embed call.
//! - `indexer`   — build/refresh the per-meeting index (idempotent, best-effort embeds).
//! - `search`    — hybrid BM25 ⊕ vector retrieval with recency weighting.
//! - `commands`  — Tauri commands for reindex + status.

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
pub mod stream;

pub use indexer::index_meeting;
