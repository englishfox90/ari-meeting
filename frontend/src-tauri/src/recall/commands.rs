//! Tauri commands for the recall index: trigger a (re)build and report status. Registered
//! in `lib.rs`.

use serde::Serialize;
use tauri::{AppHandle, Emitter, Runtime};

use crate::database::repositories::{
    meeting::MeetingsRepository, recall_index::RecallIndexRepository, setting::SettingsRepository,
};
use crate::recall::embedding::EmbedBackend;
use crate::recall::indexer;
use crate::state::AppState;

/// Return the selected recall embedder id ('apple' | 'nomic-gguf' | 'ollama'; default 'apple').
#[tauri::command]
pub async fn recall_get_embedder(state: tauri::State<'_, AppState>) -> Result<String, String> {
    let pool = state.db_manager.pool();
    Ok(crate::recall::embedding::current_backend(pool).await.id().to_string())
}

/// Persist the selected recall embedder. Vectors from different embedders aren't comparable,
/// so the caller should follow this with `recall_reindex(force=true)` to re-embed.
#[tauri::command]
pub async fn recall_set_embedder(
    state: tauri::State<'_, AppState>,
    embedder: String,
) -> Result<(), String> {
    let normalized = EmbedBackend::from_setting(Some(&embedder)).id();
    let pool = state.db_manager.pool();
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

#[tauri::command]
pub async fn recall_index_status(
    state: tauri::State<'_, AppState>,
) -> Result<RecallIndexStatus, String> {
    let pool = state.db_manager.pool();
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
#[tauri::command]
pub async fn recall_reindex<R: Runtime>(
    app: AppHandle<R>,
    state: tauri::State<'_, AppState>,
    force: Option<bool>,
) -> Result<usize, String> {
    if !indexer::try_begin_reindex() {
        return Ok(0);
    }
    let pool = state.db_manager.pool().clone();
    let force = force.unwrap_or(false);

    let meetings = MeetingsRepository::get_meetings(&pool)
        .await
        .map_err(|e| e.to_string())?;
    let total = meetings.len();

    tauri::async_runtime::spawn(async move {
        let mut done = 0usize;
        for meeting in meetings {
            if force {
                let _ = RecallIndexRepository::delete_meeting(&pool, &meeting.id).await;
            }
            indexer::index_meeting(&pool, &meeting.id).await;
            done += 1;
            let _ = app.emit(
                "recall-reindex-progress",
                serde_json::json!({ "done": done, "total": total }),
            );
        }
        indexer::end_reindex();
        let _ = app.emit("recall-reindex-complete", total);
    });

    Ok(total)
}
