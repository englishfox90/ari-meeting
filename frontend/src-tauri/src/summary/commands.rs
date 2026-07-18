//! Thin `#[tauri::command]` shims — the pure logic (response types + `_impl`
//! fns) lives in `ari_engine::summary::commands`. Per the ari-engine carve's
//! per-service migration recipe (`docs/plans/ari-engine-carve.md`), each shim
//! keeps its original fn name so `lib.rs`'s `generate_handler!` list is
//! untouched.

use ari_engine::engine::Engine;
use ari_engine::summary::commands::{
    api_cancel_summary_impl, api_detect_transcript_summary_language_impl,
    api_get_meeting_detected_summary_language_impl, api_get_meeting_summary_language_impl,
    api_get_summary_impl, api_process_transcript_impl,
    api_save_meeting_detected_summary_language_impl, api_save_meeting_summary_impl,
    api_save_meeting_summary_language_impl, MeetingSummaryLanguagePreference,
    ProcessTranscriptResponse, SummaryResponse,
};
use ari_engine::summary::language_detection::SummaryLanguageDetection;
use tauri::{AppHandle, Runtime};

/// Saves a meeting summary (Native SQLx implementation)
///
/// Expected format: { "markdown": "...", "summary_json": [...BlockNote blocks...] }
#[tauri::command]
pub async fn api_save_meeting_summary<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
    summary: serde_json::Value,
    _auth_token: Option<String>,
) -> Result<serde_json::Value, String> {
    api_save_meeting_summary_impl(&engine, meeting_id, summary).await
}

/// Gets the per-meeting summary language override from metadata.json.
#[tauri::command]
pub async fn api_get_meeting_summary_language<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
) -> Result<MeetingSummaryLanguagePreference, String> {
    api_get_meeting_summary_language_impl(&engine, meeting_id).await
}

/// Saves or clears the per-meeting summary language override in metadata.json.
#[tauri::command]
pub async fn api_save_meeting_summary_language<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
    summary_language: Option<String>,
) -> Result<MeetingSummaryLanguagePreference, String> {
    api_save_meeting_summary_language_impl(&engine, meeting_id, summary_language).await
}

/// Gets the cached Auto-detected summary language from metadata.json.
#[tauri::command]
pub async fn api_get_meeting_detected_summary_language<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
) -> Result<MeetingSummaryLanguagePreference, String> {
    api_get_meeting_detected_summary_language_impl(&engine, meeting_id).await
}

/// Saves or clears the cached Auto-detected summary language in metadata.json.
#[tauri::command]
pub async fn api_save_meeting_detected_summary_language<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
    detected_summary_language: Option<String>,
) -> Result<MeetingSummaryLanguagePreference, String> {
    api_save_meeting_detected_summary_language_impl(&engine, meeting_id, detected_summary_language)
        .await
}

/// Detects the dominant supported summary language from transcript segments.
#[tauri::command]
pub async fn api_detect_transcript_summary_language(
    transcript_texts: Vec<String>,
) -> Result<SummaryLanguageDetection, String> {
    Ok(api_detect_transcript_summary_language_impl(&transcript_texts))
}

/// Gets summary status and data (Native SQLx implementation)
///
/// Returns summary status (pending/processing/completed/failed) and parsed result data
#[tauri::command]
pub async fn api_get_summary<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
    _auth_token: Option<String>,
) -> Result<SummaryResponse, String> {
    api_get_summary_impl(&engine, meeting_id).await
}

/// Processes transcript and generates summary (Native SQLx implementation)
///
/// Spawns a background task and returns immediately with process_id
#[tauri::command]
pub async fn api_process_transcript<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    text: String,
    model: String,
    model_name: String,
    meeting_id: Option<String>,
    _chunk_size: Option<i32>,
    _overlap: Option<i32>,
    custom_prompt: Option<String>,
    template_id: Option<String>,
    summary_language: Option<String>,
    _auth_token: Option<String>,
) -> Result<ProcessTranscriptResponse, String> {
    api_process_transcript_impl(
        &engine,
        text,
        model,
        model_name,
        meeting_id,
        _chunk_size,
        _overlap,
        custom_prompt,
        template_id,
        summary_language,
        _auth_token,
    )
    .await
}

/// Cancels an ongoing summary generation process
///
/// This command triggers the cancellation token for the specified meeting,
/// stopping the summary generation gracefully.
#[tauri::command]
pub async fn api_cancel_summary<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
) -> Result<serde_json::Value, String> {
    api_cancel_summary_impl(&engine, meeting_id).await
}
