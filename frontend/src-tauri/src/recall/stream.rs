//! Streaming variant of `api_answer_meetings_locally` (F7). The streaming driver (same
//! retrieval/gating/prompt/citation invariants as the single-shot path, transport-only
//! difference) now lives in `ari_engine::recall::stream`; this module is the thin
//! `#[tauri::command]` shim, per the ari-engine carve's per-service migration recipe
//! (`docs/plans/ari-engine-carve.md`).
//!
//! Events (payloads are camelCase; all carry `streamId` so the UI can match):
//! - `ask-stream-delta` — `{ streamId, delta }` incremental text
//! - `ask-stream-done`  — `{ streamId, answer, sources }` authoritative final result

use std::sync::Arc;

use ari_engine::recall::stream as engine_stream;

use crate::api::LocalRecallTurn;
use crate::engine::Engine;

#[tauri::command]
pub async fn api_answer_meetings_locally_stream(
    engine: tauri::State<'_, Arc<Engine>>,
    stream_id: String,
    question: String,
    meeting_id: Option<String>,
    series_id: Option<String>,
    history: Option<Vec<LocalRecallTurn>>,
) -> Result<(), String> {
    engine_stream::api_answer_meetings_locally_stream_impl(
        &engine, stream_id, question, meeting_id, series_id, history,
    )
    .await
}
