//! Recall index (re)build + status — `_impl` fns for the host's `#[tauri::command]`
//! shims (`frontend/src-tauri/src/recall/commands.rs`), moved during the ari-engine
//! carve (Stage B1, `docs/plans/ari-engine-carve.md`).

use std::sync::Arc;

use serde::Serialize;

use crate::database::repositories::{
    meeting::MeetingsRepository, recall_index::RecallIndexRepository, setting::SettingsRepository,
};
use crate::engine::Engine;
use crate::recall::embedding::EmbedBackend;
use crate::recall::indexer;

/// Return the selected recall embedder id ('apple' | 'nomic-gguf' | 'ollama'; default 'apple').
pub async fn recall_get_embedder_impl(engine: &Engine) -> Result<String, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    Ok(crate::recall::embedding::current_backend(pool).await.id().to_string())
}

/// Persist the selected recall embedder. Vectors from different embedders aren't comparable,
/// so the caller should follow this with `recall_reindex(force=true)` to re-embed.
pub async fn recall_set_embedder_impl(engine: &Engine, embedder: String) -> Result<(), String> {
    let normalized = EmbedBackend::from_setting(Some(&embedder)).id();
    let db = engine.db().await?;
    let pool = db.pool();
    SettingsRepository::save_recall_embedder(pool, normalized)
        .await
        .map_err(|e| e.to_string())
}

#[derive(Debug, Serialize)]
pub struct RecallIndexStatus {
    pub indexed_meetings: i64,
    pub total_meetings: i64,
    pub chunk_count: i64,
    pub embedded_count: i64,
    /// True once at least one chunk has a semantic embedding (Ollama embedder reachable).
    pub embedding_ready: bool,
    pub reindex_running: bool,
}

pub async fn recall_index_status_impl(engine: &Engine) -> Result<RecallIndexStatus, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let (indexed_meetings, chunk_count, embedded_count) = RecallIndexRepository::index_summary(pool)
        .await
        .map_err(|e| e.to_string())?;
    let total_meetings = MeetingsRepository::get_meetings(pool)
        .await
        .map_err(|e| e.to_string())?
        .len() as i64;
    Ok(RecallIndexStatus {
        indexed_meetings,
        total_meetings,
        chunk_count,
        embedded_count,
        embedding_ready: embedded_count > 0,
        reindex_running: indexer::is_reindex_running(),
    })
}

/// Kick a background (re)index of every meeting. Returns the number of meetings queued and
/// emits `recall-reindex-progress` / `recall-reindex-complete` events for a settings UI.
/// No-op (returns 0) if a backfill is already running.
///
/// Takes an owned `Arc<Engine>` (rather than `&Engine`) because the spawned backfill task
/// below is `'static` — a borrow of `&Engine` can't escape into it, so the pool is cloned
/// out and the event sink is cloned via `Engine::event_sink` before the spawn.
pub async fn recall_reindex_impl(engine: Arc<Engine>, force: Option<bool>) -> Result<usize, String> {
    if !indexer::try_begin_reindex() {
        return Ok(0);
    }
    let db = engine.db().await?;
    let pool = db.pool().clone();
    let sink = engine.event_sink();
    let force = force.unwrap_or(false);

    let meetings = MeetingsRepository::get_meetings(&pool)
        .await
        .map_err(|e| e.to_string())?;
    let total = meetings.len();

    // Tauri's async runtime IS tokio (this is headless, Tauri-free logic — the host shim's
    // `tauri::async_runtime::spawn` and this `tokio::spawn` schedule onto the same runtime).
    tokio::spawn(async move {
        let mut done = 0usize;
        for meeting in meetings {
            if force {
                let _ = RecallIndexRepository::delete_meeting(&pool, &meeting.id).await;
            }
            indexer::index_meeting(&pool, &meeting.id).await;
            done += 1;
            sink.emit(
                "recall-reindex-progress",
                serde_json::json!({ "done": done, "total": total }),
            );
        }
        indexer::end_reindex();
        sink.emit("recall-reindex-complete", total);
    });

    Ok(total)
}
