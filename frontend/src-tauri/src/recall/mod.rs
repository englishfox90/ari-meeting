//! Recall (F7): semantic + lexical retrieval over saved meeting transcripts, plus the
//! index that powers it, plus the "Ask Meetings" safety shell. The pure logic (agent,
//! chunker, citations, context, embed_apple/runtime/sidecar, embedding, indexer, search,
//! shell) now lives in `ari-engine::recall`; this module re-exports what external host
//! callers still reach via `crate::recall::*` module paths, plus the `#[tauri::command]`
//! shims (`commands`, `conversations`, `embed_models`, `stream`) that stay host-side and
//! call straight into the moved `_impl` fns, per the ari-engine carve's per-service
//! migration recipe (`docs/plans/ari-engine-carve.md`).

pub use ari_engine::recall::{
    agent, chunker, citations, context, embed_apple, embed_runtime, embed_sidecar, embedding,
    indexer, search, shell,
};
pub use ari_engine::recall::index_meeting;

pub mod commands;
pub mod conversations;
pub mod embed_models;
pub mod stream;
