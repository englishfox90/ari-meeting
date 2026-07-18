//! Tauri commands for the recall index: trigger a (re)build and report status. Registered
//! in `lib.rs`. The pure orchestration (`*_impl` fns) now lives in
//! `ari_engine::recall::commands`; this module is the thin `#[tauri::command]` surface,
//! per the ari-engine carve's per-service migration recipe
//! (`docs/plans/ari-engine-carve.md`).

use std::sync::Arc;

use ari_engine::recall::commands as engine_commands;

pub use engine_commands::RecallIndexStatus;

use crate::engine::Engine;

#[tauri::command]
pub async fn recall_get_embedder(engine: tauri::State<'_, Arc<Engine>>) -> Result<String, String> {
    engine_commands::recall_get_embedder_impl(&engine).await
}

#[tauri::command]
pub async fn recall_set_embedder(
    engine: tauri::State<'_, Arc<Engine>>,
    embedder: String,
) -> Result<(), String> {
    engine_commands::recall_set_embedder_impl(&engine, embedder).await
}

#[tauri::command]
pub async fn recall_index_status(
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<RecallIndexStatus, String> {
    engine_commands::recall_index_status_impl(&engine).await
}

#[tauri::command]
pub async fn recall_reindex(
    engine: tauri::State<'_, Arc<Engine>>,
    force: Option<bool>,
) -> Result<usize, String> {
    engine_commands::recall_reindex_impl(engine.inner().clone(), force).await
}
