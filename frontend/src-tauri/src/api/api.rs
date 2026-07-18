use log::{debug as log_debug, error as log_error, info as log_info, warn as log_warn};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Runtime};
use tauri_plugin_dialog::DialogExt;

use crate::{
    audio::recording_preferences::{get_default_recordings_folder, load_recording_preferences},
    database::{
        models::MeetingModel,
        repositories::{
            meeting::MeetingsRepository, setting::SettingsRepository,
            transcript::TranscriptsRepository,
        },
    },
    engine::Engine,
    summary::CustomOpenAIConfig,
};

// The recall safety shell (gating, prompt assembly, bounding, `local_recall_tests`) moved
// to `ari-engine::recall::shell` during the ari-engine carve (Stage B1,
// docs/plans/ari-engine-carve.md). Re-exported here so any remaining in-file references
// (and `crate::api::*` callers elsewhere in the host) keep resolving unchanged.
pub use ari_engine::recall::{
    build_global_recall_sources, build_local_recall_context, build_local_recall_history,
    build_meeting_recall_sources, is_loopback_ollama_endpoint, is_unsupported_recall_question,
    recall_system_prompt, summary_markdown, LocalRecallResponse, LocalRecallSource, LocalRecallTurn,
};

#[derive(Debug, Serialize, Deserialize)]
pub struct ApiResponse<T> {
    pub success: bool,
    pub data: Option<T>,
    pub error: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Meeting {
    pub id: String,
    pub title: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SearchRequest {
    pub query: String,
}

pub use ari_engine::models::TranscriptSearchResult;

#[derive(Debug, Serialize)]
pub struct LocalExportResult {
    pub saved: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ModelConfig {
    pub provider: String,
    pub model: String,
    #[serde(rename = "whisperModel")]
    pub whisper_model: String,
    #[serde(rename = "apiKey")]
    pub api_key: Option<String>,
    #[serde(rename = "ollamaEndpoint")]
    pub ollama_endpoint: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveModelConfigRequest {
    pub provider: String,
    pub model: String,
    #[serde(rename = "whisperModel")]
    pub whisper_model: String,
    #[serde(rename = "apiKey")]
    pub api_key: Option<String>,
    #[serde(rename = "ollamaEndpoint")]
    pub ollama_endpoint: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct GetApiKeyRequest {
    pub provider: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TranscriptConfig {
    pub provider: String,
    pub model: String,
    #[serde(rename = "apiKey")]
    pub api_key: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveTranscriptConfigRequest {
    pub provider: String,
    pub model: String,
    #[serde(rename = "apiKey")]
    pub api_key: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DeleteMeetingRequest {
    pub meeting_id: String,
}

pub use ari_engine::models::{MeetingDetails, MeetingTranscript};

/// Meeting metadata without transcripts (for pagination)
#[derive(Debug, Serialize, Deserialize)]
pub struct MeetingMetadata {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcription_provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcription_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary_provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary_model: Option<String>,
}

/// Paginated transcripts response with total count
#[derive(Debug, Serialize, Deserialize)]
pub struct PaginatedTranscriptsResponse {
    pub transcripts: Vec<MeetingTranscript>,
    pub total_count: i64,
    pub has_more: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveMeetingTitleRequest {
    pub meeting_id: String,
    pub title: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveMeetingSummaryRequest {
    pub meeting_id: String,
    pub summary: serde_json::Value,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SaveTranscriptRequest {
    pub meeting_title: String,
    pub transcripts: Vec<TranscriptSegment>,
}

pub use ari_engine::models::TranscriptSegment;

// API Commands for Tauri

async fn api_get_meetings_impl(engine: &Engine) -> Result<Vec<Meeting>, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let meetings: Result<Vec<MeetingModel>, sqlx::Error> =
        MeetingsRepository::get_meetings(pool).await;

    match meetings {
        Ok(meeting_models) => {
            log_info!("Successfully got {} meetings", meeting_models.len());

            let result: Vec<Meeting> = meeting_models
                .into_iter()
                .map(|m| Meeting {
                    id: m.id,
                    title: m.title,
                })
                .collect();
            Ok(result)
        }
        Err(e) => {
            log_error!("Error getting meetings: {}", e);
            Err(e.to_string())
        }
    }
}

#[tauri::command]
pub async fn api_get_meetings<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    auth_token: Option<String>,
) -> Result<Vec<Meeting>, String> {
    log_info!(
        "api_get_meetings called with auth_token(native) : {}",
        auth_token.is_some()
    );
    api_get_meetings_impl(&engine).await
}

async fn api_search_transcripts_impl(
    engine: &Engine,
    query: String,
) -> Result<Vec<TranscriptSearchResult>, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    match TranscriptsRepository::search_transcripts(pool, &query).await {
        Ok(results) => {
            log_info!(
                "Search completed successfully with {} results.",
                results.len()
            );
            Ok(results)
        }
        Err(e) => {
            log_error!("Error searching transcripts for query '{}': {}", query, e);
            Err(format!("Failed to search transcripts: {}", e))
        }
    }
}

#[tauri::command]
pub async fn api_search_transcripts<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    query: String,
    auth_token: Option<String>,
) -> Result<Vec<TranscriptSearchResult>, String> {
    log_info!(
        "api_search_transcripts called with query: '{}', auth_token: {}",
        query,
        auth_token.is_some()
    );
    api_search_transcripts_impl(&engine, query).await
}

/// Answer a question only from matching local transcript snippets via a
/// configured local model. This intentionally has no cloud fallback.
#[tauri::command]
pub async fn api_answer_meetings_locally(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    question: String,
    meeting_id: Option<String>,
    series_id: Option<String>,
    history: Option<Vec<LocalRecallTurn>>,
) -> Result<LocalRecallResponse, String> {
    ari_engine::recall::api_answer_meetings_locally_impl(
        &engine, question, meeting_id, series_id, history,
    )
    .await
}

async fn api_get_model_config_impl(engine: &Engine) -> Result<Option<ModelConfig>, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    match SettingsRepository::get_model_config(pool).await {
        Ok(Some(config)) => {
            log_info!(
                "✅ Found model config in database: provider={}, model={}, whisperModel={}, ollamaEndpoint={:?}",
                &config.provider,
                &config.model,
                &config.whisper_model,
                &config.ollama_endpoint
            );
            match SettingsRepository::get_api_key(pool, &config.provider).await {
                Ok(api_key) => {
                    log_info!("Successfully retrieved model config and API key.");
                    Ok(Some(ModelConfig {
                        provider: config.provider,
                        model: config.model,
                        whisper_model: config.whisper_model,
                        api_key,
                        ollama_endpoint: config.ollama_endpoint,
                    }))
                }
                Err(e) => {
                    log_error!(
                        "Failed to get API key for provider {}: {}",
                        &config.provider,
                        e
                    );
                    Err(e.to_string())
                }
            }
        }
        Ok(None) => {
            log_warn!("⚠️ No model config found in database - database may be empty or settings table not initialized");
            Ok(None)
        }
        Err(e) => {
            log_error!("❌ Failed to get model config from database: {}", e);
            Err(e.to_string())
        }
    }
}

#[tauri::command]
pub async fn api_get_model_config(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    _auth_token: Option<String>,
) -> Result<Option<ModelConfig>, String> {
    log_info!("api_get_model_config called (native)");
    api_get_model_config_impl(&engine).await
}

async fn api_save_model_config_impl(
    engine: &Engine,
    provider: String,
    model: String,
    whisper_model: String,
    api_key: Option<String>,
    ollama_endpoint: Option<String>,
) -> Result<serde_json::Value, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    if let Err(e) = SettingsRepository::save_model_config(
        pool,
        &provider,
        &model,
        &whisper_model,
        ollama_endpoint.as_deref(),
    )
    .await
    {
        log_error!("❌ Failed to save model config to database: {}", e);
        return Err(e.to_string());
    }

    // Skip API key saving for custom-openai provider (it uses customOpenAIConfig JSON instead)
    if let Some(key) = api_key {
        if !key.is_empty() && provider != "custom-openai" {
            log_info!("🔑 API key provided, saving...");
            if let Err(e) = SettingsRepository::save_api_key(pool, &provider, &key).await {
                log_error!("❌ Failed to save API key: {}", e);
                return Err(e.to_string());
            }
        }
    }

    // Trigger graceful shutdown of built-in AI sidecar if it's running
    // This ensures that if the user switched models/providers, the old one is cleaned up
    // The shutdown happens in the background, so it won't block the UI
    if let Err(e) = crate::summary::summary_engine::client::shutdown_sidecar_gracefully().await {
        log_warn!("Failed to initiate graceful sidecar shutdown: {}", e);
    }

    log_info!("✅ Successfully saved model configuration to database");
    Ok(
        serde_json::json!({ "status": "success", "message": "Model configuration saved successfully" }),
    )
}

#[tauri::command]
pub async fn api_save_model_config(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    provider: String,
    model: String,
    whisper_model: String,
    api_key: Option<String>,
    ollama_endpoint: Option<String>,
    _auth_token: Option<String>,
) -> Result<serde_json::Value, String> {
    log_info!(
        "💾 api_save_model_config called (native): provider='{}', model='{}', whisperModel='{}', ollamaEndpoint={:?}",
        &provider,
        &model,
        &whisper_model,
        &ollama_endpoint
    );
    api_save_model_config_impl(&engine, provider, model, whisper_model, api_key, ollama_endpoint)
        .await
}

async fn api_get_api_key_impl(engine: &Engine, provider: String) -> Result<String, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    match SettingsRepository::get_api_key(pool, &provider).await {
        Ok(key) => {
            log_info!(
                "Successfully retrieved API key for provider '{}'.",
                &provider
            );
            Ok(key.unwrap_or_default())
        }
        Err(e) => {
            log_error!("Failed to get API key for provider '{}': {}", &provider, e);
            Err(e.to_string())
        }
    }
}

#[tauri::command]
pub async fn api_get_api_key(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    provider: String,
    _auth_token: Option<String>,
) -> Result<String, String> {
    log_info!(
        "api_get_api_key called (native) for provider '{}'",
        &provider
    );
    api_get_api_key_impl(&engine, provider).await
}

async fn api_get_transcript_config_impl(
    engine: &Engine,
) -> Result<Option<TranscriptConfig>, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    match SettingsRepository::get_transcript_config(pool).await {
        Ok(Some(config)) => {
            log_info!(
                "Found transcript config: provider={}, model={}",
                &config.provider,
                &config.model
            );
            match SettingsRepository::get_transcript_api_key(pool, &config.provider).await {
                Ok(api_key) => {
                    log_info!("Successfully retrieved transcript config and API key.");
                    Ok(Some(TranscriptConfig {
                        provider: config.provider,
                        model: config.model,
                        api_key,
                    }))
                }
                Err(e) => {
                    log_error!(
                        "Failed to get transcript API key for provider {}: {}",
                        &config.provider,
                        e
                    );
                    Err(e.to_string())
                }
            }
        }
        Ok(None) => {
            log_info!("No transcript config found, returning default.");
            Ok(Some(TranscriptConfig {
                provider: "parakeet".to_string(),
                model: crate::config::DEFAULT_PARAKEET_MODEL.to_string(),
                api_key: None,
            }))
        }
        Err(e) => {
            log_error!("Failed to get transcript config: {}", e);
            Err(e.to_string())
        }
    }
}

#[tauri::command]
pub async fn api_get_transcript_config(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    _auth_token: Option<String>,
) -> Result<Option<TranscriptConfig>, String> {
    log_info!("api_get_transcript_config called (native)");
    api_get_transcript_config_impl(&engine).await
}

async fn api_save_transcript_config_impl(
    engine: &Engine,
    provider: String,
    model: String,
    api_key: Option<String>,
) -> Result<serde_json::Value, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    if let Err(e) = SettingsRepository::save_transcript_config(pool, &provider, &model).await {
        log_error!("Failed to save transcript config: {}", e);
        return Err(e.to_string());
    }

    if let Some(key) = api_key {
        if !key.is_empty() {
            log_info!("API key provided, saving for transcript provider...");
            if let Err(e) = SettingsRepository::save_transcript_api_key(pool, &provider, &key).await
            {
                log_error!("Failed to save transcript API key: {}", e);
                return Err(e.to_string());
            }
        }
    }

    log_info!("Successfully saved transcript configuration.");
    Ok(
        serde_json::json!({ "status": "success", "message": "Transcript configuration saved successfully" }),
    )
}

#[tauri::command]
pub async fn api_save_transcript_config(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    provider: String,
    model: String,
    api_key: Option<String>,
    _auth_token: Option<String>,
) -> Result<serde_json::Value, String> {
    log_info!(
        "api_save_transcript_config called (native) for provider '{}'",
        &provider
    );
    api_save_transcript_config_impl(&engine, provider, model, api_key).await
}

async fn api_get_transcript_api_key_impl(
    engine: &Engine,
    provider: String,
) -> Result<String, String> {
    let db = engine.db().await?;
    match SettingsRepository::get_transcript_api_key(db.pool(), &provider).await {
        Ok(key) => {
            log_info!(
                "Successfully retrieved transcript API key for provider '{}'.",
                &provider
            );
            Ok(key.unwrap_or_default())
        }
        Err(e) => {
            log_error!(
                "Failed to get transcript API key for provider '{}': {}",
                &provider,
                e
            );
            Err(e.to_string())
        }
    }
}

#[tauri::command]
pub async fn api_get_transcript_api_key(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    provider: String,
    _auth_token: Option<String>,
) -> Result<String, String> {
    log_info!(
        "api_get_transcript_api_key called (native) for provider '{}'",
        &provider
    );
    api_get_transcript_api_key_impl(&engine, provider).await
}

async fn api_delete_api_key_impl(engine: &Engine, provider: String) -> Result<(), String> {
    let db = engine.db().await?;
    match SettingsRepository::delete_api_key(db.pool(), &provider).await {
        Ok(_) => {
            log_info!("Successfully deleted API key for provider '{}'.", &provider);
            Ok(())
        }
        Err(e) => {
            log_error!(
                "Failed to delete API key for provider '{}': {}",
                &provider,
                e
            );
            Err(e.to_string())
        }
    }
}

#[tauri::command]
pub async fn api_delete_api_key(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    provider: String,
    _auth_token: Option<String>,
) -> Result<(), String> {
    log_info!(
        "log_api_delete_api_key called (native) for provider '{}'",
        &provider
    );
    api_delete_api_key_impl(&engine, provider).await
}

fn remove_owned_meeting_folder(
    folder_path: &Path,
    allowed_recordings_roots: &[PathBuf],
) -> Result<Option<PathBuf>, String> {
    if !folder_path.is_absolute() {
        return Err("Refusing to delete a meeting folder with a relative path".to_string());
    }
    if !folder_path.exists() {
        return Ok(None);
    }

    let canonical_folder = folder_path
        .canonicalize()
        .map_err(|error| format!("Could not resolve the meeting folder: {error}"))?;
    if !canonical_folder.is_dir() {
        return Err("Refusing to delete a meeting folder path that is not a directory".to_string());
    }

    let is_owned_folder = allowed_recordings_roots.iter().any(|root| {
        root.canonicalize().ok().is_some_and(|canonical_root| {
            canonical_folder.parent() == Some(canonical_root.as_path())
        })
    });
    if !is_owned_folder {
        return Err(format!(
            "Refusing to delete a folder outside Meetily's configured recordings root: {}",
            canonical_folder.display()
        ));
    }

    std::fs::remove_dir_all(&canonical_folder).map_err(|error| {
        format!("Could not delete the meeting's local recording folder: {error}")
    })?;
    Ok(Some(canonical_folder))
}

#[cfg(test)]
mod local_meeting_folder_cleanup_tests {
    use super::remove_owned_meeting_folder;
    use std::{
        fs,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    fn test_directory(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time must be after the Unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("meetily-{label}-{}-{nonce}", std::process::id()))
    }

    #[test]
    fn removes_a_direct_child_of_the_recordings_root() {
        let base = test_directory("owned-folder");
        let recordings_root = base.join("recordings");
        let meeting_folder = recordings_root.join("meeting-1");
        fs::create_dir_all(&meeting_folder).unwrap();
        fs::write(meeting_folder.join("audio.mp4"), b"local audio").unwrap();

        let removed =
            remove_owned_meeting_folder(&meeting_folder, std::slice::from_ref(&recordings_root))
                .unwrap();

        assert!(removed.is_some());
        assert!(!meeting_folder.exists());
        assert!(recordings_root.exists());
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn treats_an_already_missing_meeting_folder_as_clean() {
        let base = test_directory("missing-folder");
        let recordings_root = base.join("recordings");
        fs::create_dir_all(&recordings_root).unwrap();
        let missing_folder = recordings_root.join("meeting-missing");

        let removed =
            remove_owned_meeting_folder(&missing_folder, std::slice::from_ref(&recordings_root))
                .unwrap();

        assert!(removed.is_none());
        assert!(recordings_root.exists());
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn refuses_a_folder_outside_the_recordings_root() {
        let base = test_directory("unsafe-folder");
        let recordings_root = base.join("recordings");
        let outside_folder = base.join("not-owned");
        fs::create_dir_all(&recordings_root).unwrap();
        fs::create_dir_all(&outside_folder).unwrap();
        fs::write(outside_folder.join("keep.txt"), b"must remain").unwrap();

        let error =
            remove_owned_meeting_folder(&outside_folder, std::slice::from_ref(&recordings_root))
                .unwrap_err();

        assert!(error.contains("outside Meetily's configured recordings root"));
        assert!(outside_folder.join("keep.txt").exists());
        let _ = fs::remove_dir_all(base);
    }
}

async fn api_delete_meeting_impl(
    engine: &Engine,
    meeting_id: String,
) -> Result<serde_json::Value, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let stored_folder: Option<(Option<String>,)> =
        sqlx::query_as("SELECT folder_path FROM meetings WHERE id = ?")
            .bind(&meeting_id)
            .fetch_optional(pool)
            .await
            .map_err(|error| format!("Failed to read the meeting's local folder: {error}"))?;

    if let Some(folder_path) = stored_folder
        .and_then(|(folder_path,)| folder_path)
        .filter(|folder_path| !folder_path.trim().is_empty())
    {
        let preferences = load_recording_preferences(engine.paths());
        let allowed_roots = vec![preferences.save_folder, get_default_recordings_folder()];
        let folder_path = PathBuf::from(folder_path);
        let removed_folder = tokio::task::spawn_blocking(move || {
            remove_owned_meeting_folder(&folder_path, &allowed_roots)
        })
        .await
        .map_err(|error| format!("Meeting folder cleanup task failed: {error}"))??;
        if let Some(removed_folder) = removed_folder {
            log_info!(
                "Deleted owned local meeting folder {} before removing meeting {}",
                removed_folder.display(),
                meeting_id
            );
        }
    }

    match MeetingsRepository::delete_meeting(pool, &meeting_id).await {
        Ok(true) => {
            log_info!("Successfully deleted meeting {}", meeting_id);
            Ok(serde_json::json!({
                "status": "success",
                "message": "Meeting deleted successfully"
            }))
        }
        Ok(false) => {
            log_warn!("Meeting not found or already deleted: {}", meeting_id);
            Err(format!(
                "Meeting not found or could not be deleted: {}",
                meeting_id
            ))
        }
        Err(e) => {
            log_error!("Error deleting meeting {}: {}", meeting_id, e);
            Err(format!("Failed to delete meeting: {}", e))
        }
    }
}

#[tauri::command]
pub async fn api_delete_meeting(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
    auth_token: Option<String>,
) -> Result<serde_json::Value, String> {
    log_info!(
        "api_delete_meeting called for meeting_id(native): {}, auth_token: {}",
        meeting_id,
        auth_token.is_some()
    );
    api_delete_meeting_impl(&engine, meeting_id).await
}

async fn api_get_meeting_impl(
    engine: &Engine,
    meeting_id: String,
) -> Result<MeetingDetails, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    match MeetingsRepository::get_meeting(pool, &meeting_id).await {
        Ok(Some(meeting)) => {
            log_info!("Successfully retrieved meeting {}", meeting_id);
            Ok(meeting)
        }
        Ok(None) => {
            log_warn!("Meeting not found: {}", meeting_id);
            Err(format!("Meeting not found: {}", meeting_id))
        }
        Err(e) => {
            log_error!("Error retrieving meeting {}: {}", meeting_id, e);
            Err(format!("Failed to retrieve meeting: {}", e))
        }
    }
}

#[tauri::command]
pub async fn api_get_meeting<R: Runtime>(
    _app: AppHandle<R>,
    meeting_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    auth_token: Option<String>,
) -> Result<MeetingDetails, String> {
    log_info!(
        "api_get_meeting called(native) for meeting_id: {}, auth_token: {}",
        meeting_id,
        auth_token.is_some()
    );
    api_get_meeting_impl(&engine, meeting_id).await
}

/// Get meeting metadata without transcripts (for pagination)
async fn api_get_meeting_metadata_impl(
    engine: &Engine,
    meeting_id: String,
) -> Result<MeetingMetadata, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    match MeetingsRepository::get_meeting_metadata(pool, &meeting_id).await {
        Ok(Some(meeting)) => {
            log_info!("Successfully retrieved meeting metadata {}", meeting_id);
            Ok(MeetingMetadata {
                id: meeting.id,
                title: meeting.title,
                created_at: meeting.created_at.0.to_rfc3339(),
                updated_at: meeting.updated_at.0.to_rfc3339(),
                folder_path: meeting.folder_path,
                transcription_provider: meeting.transcription_provider,
                transcription_model: meeting.transcription_model,
                summary_provider: meeting.summary_provider,
                summary_model: meeting.summary_model,
            })
        }
        Ok(None) => {
            log_warn!("Meeting not found: {}", meeting_id);
            Err(format!("Meeting not found: {}", meeting_id))
        }
        Err(e) => {
            log_error!("Error retrieving meeting metadata {}: {}", meeting_id, e);
            Err(format!("Failed to retrieve meeting metadata: {}", e))
        }
    }
}

/// Get meeting metadata without transcripts (for pagination)
#[tauri::command]
pub async fn api_get_meeting_metadata<R: Runtime>(
    _app: AppHandle<R>,
    meeting_id: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<MeetingMetadata, String> {
    log_info!(
        "api_get_meeting_metadata called for meeting_id: {}",
        meeting_id
    );
    api_get_meeting_metadata_impl(&engine, meeting_id).await
}

/// Get paginated transcripts for a meeting
async fn api_get_meeting_transcripts_impl(
    engine: &Engine,
    meeting_id: String,
    limit: i64,
    offset: i64,
) -> Result<PaginatedTranscriptsResponse, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    match MeetingsRepository::get_meeting_transcripts_paginated(pool, &meeting_id, limit, offset)
        .await
    {
        Ok((transcripts, total_count)) => {
            log_info!(
                "Successfully retrieved {} transcripts for meeting {} (total: {})",
                transcripts.len(),
                meeting_id,
                total_count
            );

            // Convert Transcript to MeetingTranscript
            let meeting_transcripts = transcripts
                .into_iter()
                .map(|t| MeetingTranscript {
                    id: t.id,
                    text: t.transcript,
                    timestamp: t.timestamp,
                    audio_start_time: t.audio_start_time,
                    audio_end_time: t.audio_end_time,
                    duration: t.duration,
                    speaker_id: t.speaker_id,
                })
                .collect::<Vec<_>>();

            let has_more = (offset + meeting_transcripts.len() as i64) < total_count;

            Ok(PaginatedTranscriptsResponse {
                transcripts: meeting_transcripts,
                total_count,
                has_more,
            })
        }
        Err(e) => {
            log_error!(
                "Error retrieving transcripts for meeting {}: {}",
                meeting_id,
                e
            );
            Err(format!("Failed to retrieve transcripts: {}", e))
        }
    }
}

#[tauri::command]
pub async fn api_get_meeting_transcripts<R: Runtime>(
    _app: AppHandle<R>,
    meeting_id: String,
    limit: i64,
    offset: i64,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<PaginatedTranscriptsResponse, String> {
    log_info!(
        "api_get_meeting_transcripts called for meeting_id: {}, limit: {}, offset: {}",
        meeting_id,
        limit,
        offset
    );
    api_get_meeting_transcripts_impl(&engine, meeting_id, limit, offset).await
}

async fn api_save_meeting_title_impl(
    engine: &Engine,
    meeting_id: String,
    title: String,
) -> Result<serde_json::Value, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    match MeetingsRepository::update_meeting_title(pool, &meeting_id, &title).await {
        Ok(true) => {
            log_info!("Successfully saved meeting title");
            Ok(serde_json::json!({"message": "Meeting title saved successfully"}))
        }
        Ok(false) => {
            log_error!("No meeting found with id {}", meeting_id);
            Err(format!("No meeting found with id {}", meeting_id))
        }
        Err(e) => {
            log_error!("Failed to update meeting {}", e);
            Err(format!("Failed to update meeting: {}", e))
        }
    }
}

#[tauri::command]
pub async fn api_save_meeting_title<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
    title: String,
    auth_token: Option<String>,
) -> Result<serde_json::Value, String> {
    log_info!(
        "api_save_meeting_title called for meeting_id: {}, auth_token: {}",
        meeting_id,
        auth_token.is_some()
    );
    api_save_meeting_title_impl(&engine, meeting_id, title).await
}

async fn api_save_transcript_impl(
    engine: &Engine,
    meeting_title: String,
    transcripts: Vec<serde_json::Value>,
    folder_path: Option<String>,
) -> Result<serde_json::Value, String> {
    // Log first transcript for debugging
    if let Some(first) = transcripts.first() {
        log_debug!(
            "First transcript data: {}",
            serde_json::to_string_pretty(first).unwrap_or_default()
        );
    }

    // Convert serde_json::Value to TranscriptSegment
    let transcripts_to_save: Vec<TranscriptSegment> = transcripts
        .into_iter()
        .map(serde_json::from_value)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| {
            log_error!("Failed to parse transcript segments: {}", e);
            format!(
                "Invalid transcript data format: {}. Please check the data structure.",
                e
            )
        })?;

    // Log parsed segments count and first segment details
    if let Some(first_seg) = transcripts_to_save.first() {
        log_debug!("First parsed segment: text='{}', audio_start_time={:?}, audio_end_time={:?}, duration={:?}",
                   first_seg.text.chars().take(50).collect::<String>(),
                   first_seg.audio_start_time,
                   first_seg.audio_end_time,
                   first_seg.duration);
    }

    let db = engine.db().await?;
    let pool = db.pool();

    // Resolve the transcription provider/model actually in effect at save time
    // so the meeting records what STT engine produced it (per-meeting provenance).
    // Live recordings have no provider/model in scope here, so read the current
    // transcript config (same source api_get_transcript_config uses).
    let (transcription_provider, transcription_model) =
        match SettingsRepository::get_transcript_config(pool).await {
            Ok(Some(cfg)) => (Some(cfg.provider), Some(cfg.model)),
            _ => (None, None),
        };

    // Now, call the repository with the correctly typed data.
    match TranscriptsRepository::save_transcript(
        pool,
        &meeting_title,
        &transcripts_to_save,
        folder_path,
        transcription_provider,
        transcription_model,
    )
    .await
    {
        Ok(meeting_id) => {
            log_info!(
                "Successfully saved transcript and created meeting with id: {}",
                meeting_id
            );
            // Recall (F7): index this meeting for semantic search off the hot path. The
            // save is already committed and meeting_id is in scope; failures self-log.
            {
                let pool_for_index = pool.clone();
                let meeting_id_for_index = meeting_id.clone();
                tauri::async_runtime::spawn(async move {
                    crate::recall::index_meeting(&pool_for_index, &meeting_id_for_index).await;
                });
            }
            Ok(serde_json::json!({
                "status": "success",
                "message": "Transcript saved successfully",
                "meeting_id": meeting_id
            }))
        }
        Err(e) => {
            log_error!(
                "Error saving transcript for meeting '{}': {}",
                meeting_title,
                e
            );
            Err(format!("Failed to save transcript: {}", e))
        }
    }
}

#[tauri::command]
pub async fn api_save_transcript<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_title: String,
    transcripts: Vec<serde_json::Value>,
    folder_path: Option<String>,
    auth_token: Option<String>,
) -> Result<serde_json::Value, String> {
    log_info!(
        "api_save_transcript called for meeting: {}, transcripts: {}, folder_path: {:?}, auth_token: {}",
        meeting_title,
        transcripts.len(),
        folder_path,
        auth_token.is_some()
    );
    api_save_transcript_impl(&engine, meeting_title, transcripts, folder_path).await
}

/// Returns the summary template id a meeting's summary was generated with, so
/// the Template picker can initialise to it instead of the global default.
/// `None` when the meeting has no summary yet (caller defaults to standard).
/// Backfills legacy meetings from the summary cache blob (see repository).
async fn api_get_meeting_template_impl(
    engine: &Engine,
    meeting_id: String,
) -> Result<Option<String>, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    MeetingsRepository::get_summary_template(pool, &meeting_id)
        .await
        .map_err(|e| format!("Failed to read meeting template: {}", e))
}

#[tauri::command]
pub async fn api_get_meeting_template(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
) -> Result<Option<String>, String> {
    api_get_meeting_template_impl(&engine, meeting_id).await
}

/// Opens the meeting's recording folder in the system file explorer
async fn open_meeting_folder_impl(engine: &Engine, meeting_id: String) -> Result<(), String> {
    let db = engine.db().await?;
    let pool = db.pool();

    // Get meeting with folder_path
    let meeting: Option<MeetingModel> = sqlx::query_as(
        "SELECT id, title, created_at, updated_at, folder_path, transcription_provider, transcription_model, summary_provider, summary_model FROM meetings WHERE id = ?",
    )
    .bind(&meeting_id)
    .fetch_optional(pool)
    .await
    .map_err(|e| format!("Database error: {}", e))?;

    match meeting {
        Some(m) => {
            if let Some(folder_path) = m.folder_path {
                log_info!("Opening meeting folder: {}", folder_path);

                // Verify folder exists
                let path = std::path::Path::new(&folder_path);
                if !path.exists() {
                    log_warn!("Folder path does not exist: {}", folder_path);
                    return Err(format!("Recording folder not found: {}", folder_path));
                }

                // Open folder based on OS
                #[cfg(target_os = "macos")]
                {
                    std::process::Command::new("open")
                        .arg(&folder_path)
                        .spawn()
                        .map_err(|e| format!("Failed to open folder: {}", e))?;
                }

                #[cfg(target_os = "windows")]
                {
                    std::process::Command::new("explorer")
                        .arg(&folder_path)
                        .spawn()
                        .map_err(|e| format!("Failed to open folder: {}", e))?;
                }

                #[cfg(target_os = "linux")]
                {
                    std::process::Command::new("xdg-open")
                        .arg(&folder_path)
                        .spawn()
                        .map_err(|e| format!("Failed to open folder: {}", e))?;
                }

                log_info!("Successfully opened folder: {}", folder_path);
                Ok(())
            } else {
                log_warn!("Meeting {} has no folder_path set", meeting_id);
                Err("Recording folder path not available for this meeting".to_string())
            }
        }
        None => {
            log_warn!("Meeting not found: {}", meeting_id);
            Err("Meeting not found".to_string())
        }
    }
}

#[tauri::command]
pub async fn open_meeting_folder<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
) -> Result<(), String> {
    log_info!("open_meeting_folder called for meeting_id: {}", meeting_id);
    open_meeting_folder_impl(&engine, meeting_id).await
}

fn build_local_meeting_export(
    title: &str,
    created_at: &str,
    updated_at: &str,
    summary: Option<&str>,
    transcripts: &[(String, String)],
) -> String {
    let summary_section = summary
        .map(str::trim)
        .filter(|summary| !summary.is_empty())
        .map(|summary| format!("\n\n## Summary\n\n{summary}"))
        .unwrap_or_default();
    let transcript = transcripts
        .iter()
        .map(|(timestamp, text)| format!("- {timestamp} {text}"))
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "# {title}\n\nCreated: {created_at}\nUpdated: {updated_at}{summary_section}\n\n## Transcript\n\n{transcript}\n"
    )
}

/// Exports only persisted local meeting fields after the user chooses a destination.
async fn api_export_meeting_locally_impl<R: Runtime>(
    engine: &Engine,
    app: AppHandle<R>,
    meeting_id: String,
) -> Result<LocalExportResult, String> {
    let db = engine.db().await?;
    let pool = db.pool();
    let meeting: Option<MeetingModel> = sqlx::query_as(
        "SELECT id, title, created_at, updated_at, folder_path, transcription_provider, transcription_model, summary_provider, summary_model FROM meetings WHERE id = ?",
    )
    .bind(&meeting_id)
    .fetch_optional(pool)
    .await
    .map_err(|error| format!("Could not read the local meeting: {error}"))?;
    let Some(meeting) = meeting else {
        return Err("Meeting not found".to_string());
    };

    let transcripts: Vec<(String, String)> = sqlx::query_as(
        "SELECT timestamp, transcript FROM transcripts WHERE meeting_id = ? ORDER BY timestamp ASC",
    )
    .bind(&meeting_id)
    .fetch_all(pool)
    .await
    .map_err(|error| format!("Could not read local transcripts: {error}"))?;
    let saved_summary: Option<(Option<String>,)> = sqlx::query_as(
        "SELECT result FROM summary_processes WHERE meeting_id = ? AND status = 'completed'",
    )
    .bind(&meeting_id)
    .fetch_optional(pool)
    .await
    .map_err(|error| format!("Could not read the local meeting summary: {error}"))?;
    let summary = saved_summary
        .and_then(|(result,)| result)
        .as_deref()
        .and_then(summary_markdown);

    let filename = format!("{}.md", meeting.title.replace(['/', ':'], "-"));
    let Some(path) = app
        .dialog()
        .file()
        .set_file_name(&filename)
        .blocking_save_file()
    else {
        return Ok(LocalExportResult { saved: false });
    };
    let contents = build_local_meeting_export(
        &meeting.title,
        &meeting.created_at.0.to_rfc3339(),
        &meeting.updated_at.0.to_rfc3339(),
        summary.as_deref(),
        &transcripts,
    );
    let path = path
        .as_path()
        .ok_or_else(|| "The selected export destination is not a local path".to_string())?;
    std::fs::write(path, contents)
        .map_err(|error| format!("Could not write the local export: {error}"))?;
    Ok(LocalExportResult { saved: true })
}

#[tauri::command]
pub async fn api_export_meeting_locally<R: Runtime>(
    app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    meeting_id: String,
) -> Result<LocalExportResult, String> {
    api_export_meeting_locally_impl(&engine, app, meeting_id).await
}

#[cfg(test)]
mod local_export_tests {
    use super::build_local_meeting_export;

    #[test]
    fn local_export_includes_saved_summary_and_transcript() {
        let transcripts = vec![("00:10".to_string(), "Real spoken text.".to_string())];
        let export = build_local_meeting_export(
            "Strategy review",
            "2026-07-13T10:00:00Z",
            "2026-07-13T10:30:00Z",
            Some("**Summary**\nPreserve the exact record."),
            &transcripts,
        );

        assert!(export.contains("## Summary\n\n**Summary**"));
        assert!(export.contains("## Transcript\n\n- 00:10 Real spoken text."));
    }

    #[test]
    fn local_export_without_a_summary_remains_transcript_only() {
        let transcripts = vec![("00:10".to_string(), "Real spoken text.".to_string())];
        let export = build_local_meeting_export(
            "Strategy review",
            "2026-07-13T10:00:00Z",
            "2026-07-13T10:30:00Z",
            None,
            &transcripts,
        );

        assert!(!export.contains("## Summary"));
        assert!(export.contains("## Transcript\n\n- 00:10 Real spoken text."));
    }
}

#[tauri::command]
pub async fn open_external_url(url: String) -> Result<(), String> {
    use std::process::Command;

    let result = if cfg!(target_os = "windows") {
        Command::new("cmd").args(&["/C", "start", &url]).output()
    } else if cfg!(target_os = "macos") {
        Command::new("open").arg(&url).output()
    } else {
        // Linux and other Unix-like systems
        Command::new("xdg-open").arg(&url).output()
    };

    match result {
        Ok(_) => Ok(()),
        Err(e) => Err(format!("Failed to open URL: {}", e)),
    }
}

// ===== CUSTOM OPENAI API COMMANDS =====

/// Saves the custom OpenAI configuration
/// This configuration is stored as JSON and includes endpoint, apiKey, model, and optional parameters
async fn api_save_custom_openai_config_impl(
    engine: &Engine,
    endpoint: String,
    api_key: Option<String>,
    model: String,
    max_tokens: Option<i32>,
    temperature: Option<f32>,
    top_p: Option<f32>,
) -> Result<serde_json::Value, String> {
    // Validate required fields
    if endpoint.trim().is_empty() {
        return Err("Endpoint URL is required".to_string());
    }
    if model.trim().is_empty() {
        return Err("Model name is required".to_string());
    }

    // Validate endpoint URL format
    if !endpoint.starts_with("http://") && !endpoint.starts_with("https://") {
        return Err("Endpoint must start with http:// or https://".to_string());
    }

    // Validate optional numeric parameters
    if let Some(temp) = temperature {
        if !(0.0..=2.0).contains(&temp) {
            return Err("Temperature must be between 0.0 and 2.0".to_string());
        }
    }
    if let Some(top) = top_p {
        if !(0.0..=1.0).contains(&top) {
            return Err("Top P must be between 0.0 and 1.0".to_string());
        }
    }
    if let Some(tokens) = max_tokens {
        if tokens < 1 {
            return Err("Max tokens must be at least 1".to_string());
        }
    }

    let config = CustomOpenAIConfig {
        endpoint: endpoint.trim().to_string(),
        api_key: api_key.filter(|k| !k.trim().is_empty()),
        model: model.trim().to_string(),
        max_tokens,
        temperature,
        top_p,
    };

    let db = engine.db().await?;
    let pool = db.pool();

    match SettingsRepository::save_custom_openai_config(pool, &config).await {
        Ok(()) => {
            log_info!(
                "✅ Successfully saved custom OpenAI config for endpoint: {}",
                config.endpoint
            );
            Ok(serde_json::json!({
                "status": "success",
                "message": "Custom OpenAI configuration saved successfully"
            }))
        }
        Err(e) => {
            log_error!("❌ Failed to save custom OpenAI config: {}", e);
            Err(format!("Failed to save custom OpenAI configuration: {}", e))
        }
    }
}

#[tauri::command]
pub async fn api_save_custom_openai_config<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    endpoint: String,
    api_key: Option<String>,
    model: String,
    max_tokens: Option<i32>,
    temperature: Option<f32>,
    top_p: Option<f32>,
) -> Result<serde_json::Value, String> {
    log_info!(
        "api_save_custom_openai_config called: endpoint='{}', model='{}'",
        &endpoint,
        &model
    );
    api_save_custom_openai_config_impl(
        &engine,
        endpoint,
        api_key,
        model,
        max_tokens,
        temperature,
        top_p,
    )
    .await
}

/// Gets the custom OpenAI configuration
async fn api_get_custom_openai_config_impl(
    engine: &Engine,
) -> Result<Option<CustomOpenAIConfig>, String> {
    let db = engine.db().await?;
    let pool = db.pool();

    match SettingsRepository::get_custom_openai_config(pool).await {
        Ok(config) => {
            if let Some(ref c) = config {
                log_info!(
                    "✅ Found custom OpenAI config: endpoint='{}', model='{}'",
                    c.endpoint,
                    c.model
                );
            } else {
                log_info!("No custom OpenAI config found");
            }
            Ok(config)
        }
        Err(e) => {
            log_error!("❌ Failed to get custom OpenAI config: {}", e);
            Err(format!("Failed to get custom OpenAI configuration: {}", e))
        }
    }
}

#[tauri::command]
pub async fn api_get_custom_openai_config<R: Runtime>(
    _app: AppHandle<R>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Option<CustomOpenAIConfig>, String> {
    log_info!("api_get_custom_openai_config called");
    api_get_custom_openai_config_impl(&engine).await
}

/// Tests the connection to a custom OpenAI-compatible endpoint
/// Makes a minimal request to verify the endpoint is reachable and responds correctly
#[tauri::command]
pub async fn api_test_custom_openai_connection<R: Runtime>(
    _app: AppHandle<R>,
    endpoint: String,
    api_key: Option<String>,
    model: String,
) -> Result<serde_json::Value, String> {
    log_info!(
        "api_test_custom_openai_connection called: endpoint='{}', model='{}'",
        &endpoint,
        &model
    );

    // Validate endpoint URL format
    if !endpoint.starts_with("http://") && !endpoint.starts_with("https://") {
        return Err("Endpoint must start with http:// or https://".to_string());
    }

    // Build the URL - append /chat/completions to the base endpoint
    let url = format!("{}/chat/completions", endpoint.trim_end_matches('/'));

    // Create a minimal test request
    let test_request = serde_json::json!({
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": "Hi"
            }
        ],
        "max_tokens": 5
    });

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let mut request = client
        .post(&url)
        .header("Content-Type", "application/json")
        .json(&test_request);

    // Add authorization if API key provided
    if let Some(key) = api_key.filter(|k| !k.trim().is_empty()) {
        request = request.header("Authorization", format!("Bearer {}", key));
    }

    match request.send().await {
        Ok(response) => {
            let status = response.status();
            let response_text = response.text().await.unwrap_or_default();

            if status.is_success() {
                // Parse response as JSON to verify it's a valid OpenAI-compatible response
                match serde_json::from_str::<serde_json::Value>(&response_text) {
                    Ok(json) => {
                        // Verify the response has the expected OpenAI structure
                        if let Some(choices) = json.get("choices") {
                            if let Some(choices_array) = choices.as_array() {
                                if !choices_array.is_empty() {
                                    // Verify the first choice has the required message structure
                                    if let Some(first_choice) = choices_array.get(0) {
                                        // Check if message.content field exists (can be empty string)
                                        let has_message_structure = first_choice
                                            .get("message")
                                            .and_then(|m| {
                                                m.get("content")
                                                    .or_else(|| m.get("reasoning_content"))
                                            })
                                            .is_some();

                                        if has_message_structure {
                                            log_info!("✅ Custom OpenAI connection test successful - response validated");
                                            return Ok(serde_json::json!({
                                                "status": "success",
                                                "message": "Connection successful and response validated",
                                                "http_status": status.as_u16()
                                            }));
                                        }
                                    }
                                }
                            }
                        }

                        // Response was 200 but doesn't match OpenAI format
                        log_warn!(
                            "⚠️ Endpoint returned 200 but response doesn't match OpenAI format: {}",
                            response_text
                        );
                        Err("Endpoint is reachable but doesn't appear to be OpenAI-compatible. Response is missing 'choices' array or 'message.content' / 'message.reasoning_content' field.".to_string())
                    }
                    Err(e) => {
                        log_warn!(
                            "⚠️ Endpoint returned 200 but response is not valid JSON: {}",
                            e
                        );
                        Err(format!(
                            "Endpoint is reachable but returned invalid JSON: {}. Response: {}",
                            e, response_text
                        ))
                    }
                }
            } else {
                log_warn!(
                    "⚠️ Custom OpenAI connection test failed with status {}: {}",
                    status,
                    response_text
                );
                Err(format!(
                    "Connection failed with status {}: {}",
                    status, response_text
                ))
            }
        }
        Err(e) => {
            log_error!("❌ Custom OpenAI connection test failed: {}", e);
            if e.is_timeout() {
                Err("Connection timed out. Please check the endpoint URL.".to_string())
            } else if e.is_connect() {
                Err("Could not connect to endpoint. Please verify the URL is correct and the server is running.".to_string())
            } else {
                Err(format!("Connection failed: {}", e))
            }
        }
    }
}
