use serde::{Deserialize, Serialize};
use log::{info, error};
use anyhow::Result;

use crate::database::repositories::setting::SettingsRepository;
use crate::engine::{json_store, Engine, Paths};


#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct OnboardingStatus {
    pub version: String,
    pub completed: bool,
    pub current_step: u8,
    pub model_status: ModelStatus,
    pub last_updated: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ModelStatus {
    pub parakeet: String,  // "downloaded" | "not_downloaded" | "downloading"
    pub summary: String,   // Generic field for summary model (Qwen 3.5 or legacy Gemma variants)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_summary_model: Option<String>,
}

impl Default for OnboardingStatus {
    fn default() -> Self {
        Self {
            version: "1.0".to_string(),
            completed: false,
            current_step: 1,
            model_status: ModelStatus {
                parakeet: "not_downloaded".to_string(),
                summary: "not_downloaded".to_string(),  // Changed from gemma
                selected_summary_model: None,
            },
            last_updated: chrono::Utc::now().to_rfc3339(),
        }
    }
}


const ONBOARDING_STORE_FILE: &str = "onboarding-status.json";
const ONBOARDING_STATUS_KEY: &str = "status";

/// Load onboarding status from its headless JSON-store file
/// (`<app_data>/onboarding-status.json`, same location the Tauri store plugin
/// used — see `engine::json_store`).
pub fn load_onboarding_status(paths: &Paths) -> OnboardingStatus {
    match json_store::get::<OnboardingStatus>(paths, ONBOARDING_STORE_FILE, ONBOARDING_STATUS_KEY)
    {
        Some(s) => {
            info!(
                "Loaded onboarding status from store - Step: {}, Completed: {}",
                s.current_step, s.completed
            );
            s
        }
        None => {
            info!("No stored onboarding status found, using defaults");
            OnboardingStatus::default()
        }
    }
}

/// Save onboarding status to its headless JSON-store file.
pub fn save_onboarding_status(paths: &Paths, status: &OnboardingStatus) -> Result<()> {
    info!(
        "Saving onboarding status: step={}, completed={}",
        status.current_step, status.completed
    );

    let mut status = status.clone();
    status.last_updated = chrono::Utc::now().to_rfc3339();

    json_store::set(paths, ONBOARDING_STORE_FILE, ONBOARDING_STATUS_KEY, &status)
        .map_err(|e| anyhow::anyhow!("Failed to save onboarding status: {}", e))?;

    info!("Successfully persisted onboarding status to disk");
    Ok(())
}

/// Reset onboarding status (delete the key from the store file). Currently
/// unused (no command wires to it) — kept for parity with the pre-carve
/// behavior; ported onto the same headless store.
#[allow(dead_code)]
pub fn reset_onboarding_status(paths: &Paths) -> Result<()> {
    info!("Resetting onboarding status");

    json_store::delete(paths, ONBOARDING_STORE_FILE, ONBOARDING_STATUS_KEY)
        .map_err(|e| anyhow::anyhow!("Failed to reset onboarding status: {}", e))?;

    info!("Successfully reset onboarding status");
    Ok(())
}

/// Tauri commands for onboarding status
#[tauri::command]
pub async fn get_onboarding_status(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Option<OnboardingStatus>, String> {
    let paths = engine.paths();

    // Return None if it's the default (never saved before) — distinguish
    // "no saved data" from "saved defaults" by checking key presence.
    if !json_store::has_key(paths, ONBOARDING_STORE_FILE, ONBOARDING_STATUS_KEY) {
        return Ok(None);
    }

    Ok(Some(load_onboarding_status(paths)))
}

#[tauri::command]
pub async fn save_onboarding_status_cmd(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    status: OnboardingStatus,
) -> Result<(), String> {
    save_onboarding_status(engine.paths(), &status)
        .map_err(|e| format!("Failed to save onboarding status: {}", e))
}

/// Pure engine logic for completing onboarding — takes `&Engine` for DB access
/// and onboarding-status persistence (the Stage-A carve pattern: a
/// `#[tauri::command]` shim unwraps managed state and calls this). See
/// `docs/plans/ari-engine-carve.md`.
///
/// Onboarding status now persists through the headless `engine::json_store`
/// (Stage B, Seam 1) rather than the Tauri store plugin, so this fn no longer
/// needs an `AppHandle` at all — everything flows through `&Engine`.
pub async fn complete_onboarding_impl(
    engine: &Engine,
    model: String,
    summary_provider: Option<String>,
    transcription_provider: Option<String>,
    transcription_model: Option<String>,
) -> Result<(), String> {
    let summary_provider = summary_provider.as_deref().unwrap_or("builtin-ai");
    let transcription_provider = transcription_provider.as_deref().unwrap_or("parakeet");
    let transcription_model = transcription_model
        .as_deref()
        .unwrap_or(crate::config::DEFAULT_PARAKEET_MODEL);

    info!(
        "Completing onboarding: summary_provider={}, model={}, transcription_provider={}, transcription_model={}",
        summary_provider, model, transcription_provider, transcription_model
    );

    // Step 1: Save model configuration to SQLite database FIRST.
    // DB now flows through the engine context (deferred-init DB manager).
    let db = engine.db().await?;
    let pool = db.pool();

    if let Err(e) = SettingsRepository::save_model_config(
        pool,
        summary_provider,
        &model,
        "large-v3",
        None,
    ).await {
        error!("Failed to save summary model config: {}", e);
        return Err(format!("Failed to save summary model config: {}", e));
    }
    info!("Saved summary model config: provider={}, model={}", summary_provider, model);

    // Save transcription model config.
    if let Err(e) = SettingsRepository::save_transcript_config(
        pool,
        transcription_provider,
        transcription_model,
    ).await {
        error!("Failed to save transcription model config: {}", e);
        return Err(format!("Failed to save transcription model config: {}", e));
    }
    info!("Saved transcription model config: provider={}, model={}", transcription_provider, transcription_model);

    // Step 2: Only NOW mark onboarding as complete (after DB operations succeed)
    let mut status = load_onboarding_status(engine.paths());

    status.completed = true;
    status.current_step = 4; // Max step (4 on macOS with permissions, 3 on other platforms)
    status.model_status.parakeet = "downloaded".to_string();
    status.model_status.summary = "downloaded".to_string();
    status.model_status.selected_summary_model = Some(model.clone());

    save_onboarding_status(engine.paths(), &status)
        .map_err(|e| format!("Failed to save completed onboarding status: {}", e))?;

    info!("Onboarding completed successfully with model: {}", model);
    Ok(())
}

/// Thin Tauri-command shim: unwraps the managed `Arc<Engine>` and forwards to
/// [`complete_onboarding_impl`]. Registered unchanged in `lib.rs`, so the
/// frontend IPC contract is identical. The `summary_provider` /
/// `transcription_*` optionals keep Tauri's camelCase→snake_case mapping; an
/// absent key stays `None`, preserving the historical builtin-ai/parakeet
/// defaults inside the impl.
#[tauri::command]
pub async fn complete_onboarding(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
    model: String,
    summary_provider: Option<String>,
    transcription_provider: Option<String>,
    transcription_model: Option<String>,
) -> Result<(), String> {
    complete_onboarding_impl(
        &engine,
        model,
        summary_provider,
        transcription_provider,
        transcription_model,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn onboarding_status_deserializes_without_selected_summary_model() {
        let status: OnboardingStatus = serde_json::from_str(
            r#"{
                "version": "1.0",
                "completed": true,
                "current_step": 4,
                "model_status": {
                    "parakeet": "downloaded",
                    "summary": "downloaded"
                },
                "last_updated": "2026-05-30T00:00:00Z"
            }"#,
        )
        .expect("old onboarding status should remain compatible");

        assert_eq!(status.model_status.selected_summary_model, None);
    }
}
