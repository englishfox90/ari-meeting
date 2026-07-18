// Meeting Series (F9) — Tauri command surface. Registered as `meeting_series::commands::*`
// in `lib.rs`'s `generate_handler!` list. The pure `*_impl` logic now lives in
// `ari-engine::meeting_series::commands`; these are thin shims per the ari-engine carve's
// per-service migration recipe (`docs/plans/ari-engine-carve.md`).

use crate::engine::Engine;
use ari_engine::meeting_series::commands as engine_commands;
use ari_engine::meeting_series::models::{SeriesDetail, SeriesForMeeting, SeriesSummary};

#[tauri::command]
pub async fn series_list(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<SeriesSummary>, String> {
    engine_commands::series_list_impl(&engine).await
}

#[tauri::command]
pub async fn series_get(
    series_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<SeriesDetail, String> {
    engine_commands::series_get_impl(&engine, series_id).await
}

#[tauri::command]
pub async fn series_for_meeting(
    meeting_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Option<SeriesForMeeting>, String> {
    engine_commands::series_for_meeting_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn series_create(
    title: String,
    detected_type: Option<String>,
    cadence: Option<String>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<String, String> {
    engine_commands::series_create_impl(&engine, title, detected_type, cadence).await
}

#[tauri::command]
pub async fn series_link_meeting(
    meeting_id: String,
    series_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_commands::series_link_meeting_impl(&engine, meeting_id, series_id).await
}

#[tauri::command]
pub async fn series_unlink_meeting(
    meeting_id: String,
    series_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_commands::series_unlink_meeting_impl(&engine, meeting_id, series_id).await
}

#[tauri::command]
pub async fn series_update_meta(
    series_id: String,
    title: String,
    detected_type: Option<String>,
    cadence: Option<String>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_commands::series_update_meta_impl(&engine, series_id, title, detected_type, cadence)
        .await
}

#[tauri::command]
pub async fn series_rescan_heuristic(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<usize, String> {
    engine_commands::series_rescan_heuristic_impl(&engine).await
}

#[tauri::command]
pub async fn series_set_template(
    meeting_id: String,
    template_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_commands::series_set_template_impl(&engine, meeting_id, template_id).await
}

#[tauri::command]
pub async fn series_update_ledger(
    meeting_id: String,
    _app: tauri::AppHandle,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_commands::series_update_ledger_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn series_rebuild_ledger(
    series_id: String,
    _app: tauri::AppHandle,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Option<String>, String> {
    engine_commands::series_rebuild_ledger_impl(&engine, series_id).await
}
