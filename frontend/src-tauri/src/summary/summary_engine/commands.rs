// Tauri commands for built-in AI model management
// Exposes model download, status, and management functionality to frontend

use std::sync::Arc;

use tauri::{AppHandle, Manager, Runtime, State};
use tokio::sync::Mutex;

use crate::engine::Engine;

use super::model_manager::{DownloadProgress, ModelInfo, ModelManager};

const QWEN35_4B_RECOMMENDED_RAM_GB: u64 = 14;

pub(crate) fn summary_model_priority(model_name: &str) -> u8 {
    match model_name {
        "qwen3.5:4b" => 4,
        "qwen3.5:2b" => 3,
        "gemma3:4b" => 2,
        "gemma3:1b" => 1,
        _ => 0,
    }
}

pub(crate) fn recommend_summary_model(_is_macos: bool, system_ram_gb: u64) -> &'static str {
    if system_ram_gb >= QWEN35_4B_RECOMMENDED_RAM_GB {
        "qwen3.5:4b"
    } else {
        "qwen3.5:2b"
    }
}

pub(crate) fn get_recommended_summary_model_for_current_system() -> Result<&'static str, String> {
    let system_ram_gb = get_system_ram_gb()?;
    let is_macos = cfg!(target_os = "macos");

    log::info!(
        "System RAM detected: {} GB, Platform: {}",
        system_ram_gb,
        if is_macos { "macOS" } else { "other" }
    );

    Ok(recommend_summary_model(is_macos, system_ram_gb))
}

// ============================================================================
// Global State
// ============================================================================

/// Global model manager instance
pub struct ModelManagerState(pub Arc<Mutex<Option<Arc<ModelManager>>>>);

/// Initialize the model manager
pub async fn init_model_manager(engine: &Engine) -> anyhow::Result<()> {
    let models_dir = engine.paths().summary_models();

    let manager = ModelManager::new_with_models_dir(Some(models_dir))?;
    manager.init().await?;

    let mut manager_lock = engine.summary_models().0.lock().await;
    *manager_lock = Some(Arc::new(manager));

    log::info!("Built-in AI model manager initialized");
    Ok(())
}

// ============================================================================
// Tauri Commands
// ============================================================================

async fn builtin_ai_list_models_impl(engine: &Engine) -> Result<Vec<ModelInfo>, String> {
    let manager = {
        // Ensure manager is initialized
        {
            let manager_lock = engine.summary_models().0.lock().await;
            if manager_lock.is_none() {
                drop(manager_lock);
                init_model_manager(engine)
                    .await
                    .map_err(|e| format!("Failed to initialize model manager: {}", e))?;
            }
        }

        let manager_lock = engine.summary_models().0.lock().await;
        manager_lock
            .as_ref()
            .ok_or_else(|| "Model manager not initialized".to_string())?
            .clone()
    };

    let models = manager.list_models().await;
    Ok(models)
}

/// List all available built-in AI models with their status
#[tauri::command]
pub async fn builtin_ai_list_models(
    engine: State<'_, Arc<Engine>>,
) -> Result<Vec<ModelInfo>, String> {
    builtin_ai_list_models_impl(&engine).await
}

async fn builtin_ai_get_model_info_impl(
    engine: &Engine,
    model_name: String,
) -> Result<Option<ModelInfo>, String> {
    let manager = {
        // Ensure manager is initialized
        {
            let manager_lock = engine.summary_models().0.lock().await;
            if manager_lock.is_none() {
                drop(manager_lock);
                init_model_manager(engine)
                    .await
                    .map_err(|e| format!("Failed to initialize model manager: {}", e))?;
            }
        }

        let manager_lock = engine.summary_models().0.lock().await;
        manager_lock
            .as_ref()
            .ok_or_else(|| "Model manager not initialized".to_string())?
            .clone()
    };

    let info = manager.get_model_info(&model_name).await;
    Ok(info)
}

/// Get information about a specific model
#[tauri::command]
pub async fn builtin_ai_get_model_info(
    engine: State<'_, Arc<Engine>>,
    model_name: String,
) -> Result<Option<ModelInfo>, String> {
    builtin_ai_get_model_info_impl(&engine, model_name).await
}

// Takes an owned `Arc<Engine>` (rather than `&Engine`) because the progress callback below is
// a `Box<dyn Fn(DownloadProgress) + Send>` — an owned trait object defaults to `'static`, so it
// cannot capture a borrowed `&Engine`. Cloning the Arc into the closure keeps the callback valid
// for the life of the download.
async fn builtin_ai_download_model_impl(
    engine: Arc<Engine>,
    model_name: String,
) -> Result<(), String> {
    let manager = {
        // Ensure manager is initialized
        {
            let manager_lock = engine.summary_models().0.lock().await;
            if manager_lock.is_none() {
                drop(manager_lock);
                init_model_manager(&engine)
                    .await
                    .map_err(|e| format!("Failed to initialize model manager: {}", e))?;
            }
        }

        let manager_lock = engine.summary_models().0.lock().await;
        manager_lock
            .as_ref()
            .ok_or_else(|| "Model manager not initialized".to_string())?
            .clone() // Clone the Arc, not the ModelManager
    };
    // IMPORTANT: Only emit "downloading" status here, never "completed"
    // Completion event is emitted AFTER download task fully finishes (validation, etc.)
    // Owned sink for the 'static progress callback + the post-download emits
    // (a borrow via engine.events() can't escape into the callback).
    let sink = engine.event_sink();
    let sink_cb = sink.clone();
    let model_name_clone = model_name.clone();
    let progress_callback = Box::new(move |progress: DownloadProgress| {
        sink_cb.emit(
            "builtin-ai-download-progress",
            serde_json::json!({
                "model": model_name_clone,
                "progress": progress.percent,
                "downloaded_mb": progress.downloaded_mb,
                "total_mb": progress.total_mb,
                "speed_mbps": progress.speed_mbps,
                "status": "downloading"  // Always "downloading", never "completed" from progress callback
            }),
        );
    });

    match manager
        .download_model_detailed(&model_name, Some(progress_callback))
        .await
    {
        Ok(_) => {
            // Download task completed successfully (validation passed, status set to Available)
            sink.emit(
                "builtin-ai-download-progress",
                serde_json::json!({
                    "model": model_name,
                    "progress": 100,
                    "downloaded_mb": 0,  // Not used by completion handler
                    "total_mb": 0,       // Not used by completion handler
                    "speed_mbps": 0,     // Not used by completion handler
                    "status": "completed"
                }),
            );
            Ok(())
        },
        Err(e) => {
            let error_msg = e.to_string();

            // Check if this is a cancellation error (marked with "CANCELLED:" prefix)
            // Don't emit error event for cancellations - cancel command already emits cancelled event
            if !error_msg.starts_with("CANCELLED:") {
                // Emit error via progress event for frontend to display (only for real errors)
                sink.emit(
                    "builtin-ai-download-progress",
                    serde_json::json!({
                        "model": model_name,
                        "progress": 0,
                        "downloaded_mb": 0,
                        "total_mb": 0,
                        "speed_mbps": 0,
                        "status": "error",
                        "error": error_msg
                    }),
                );
            }
            Err(error_msg)
        }
    }
}

/// Download a built-in AI model with progress updates
#[tauri::command]
pub async fn builtin_ai_download_model(
    engine: State<'_, Arc<Engine>>,
    model_name: String,
) -> Result<(), String> {
    builtin_ai_download_model_impl(engine.inner().clone(), model_name).await
}

async fn builtin_ai_cancel_download_impl(
    engine: &Engine,
    model_name: String,
) -> Result<(), String> {
    let manager = {
        let manager_lock = engine.summary_models().0.lock().await;
        manager_lock
            .as_ref()
            .ok_or_else(|| "Model manager not initialized".to_string())?
            .clone()
    };

    manager
        .cancel_download(&model_name)
        .await
        .map_err(|e| e.to_string())?;

    engine.event_sink().emit(
        "builtin-ai-download-progress",
        serde_json::json!({
            "model": model_name,
            "progress": 0,
            "status": "cancelled"
        }),
    );

    Ok(())
}

/// Cancel an ongoing model download
#[tauri::command]
pub async fn builtin_ai_cancel_download(
    engine: State<'_, Arc<Engine>>,
    model_name: String,
) -> Result<(), String> {
    builtin_ai_cancel_download_impl(&engine, model_name).await
}

async fn builtin_ai_delete_model_impl(engine: &Engine, model_name: String) -> Result<(), String> {
    let manager = {
        let manager_lock = engine.summary_models().0.lock().await;
        manager_lock
            .as_ref()
            .ok_or_else(|| "Model manager not initialized".to_string())?
            .clone()
    };

    manager
        .delete_model(&model_name)
        .await
        .map_err(|e| e.to_string())
}

/// Delete a corrupted or available model file
#[tauri::command]
pub async fn builtin_ai_delete_model(
    engine: State<'_, Arc<Engine>>,
    model_name: String,
) -> Result<(), String> {
    builtin_ai_delete_model_impl(&engine, model_name).await
}

async fn builtin_ai_is_model_ready_impl(
    engine: &Engine,
    model_name: String,
    refresh: Option<bool>,
) -> Result<bool, String> {
    let manager = {
        // Ensure manager is initialized
        {
            let manager_lock = engine.summary_models().0.lock().await;
            if manager_lock.is_none() {
                drop(manager_lock);
                init_model_manager(engine)
                    .await
                    .map_err(|e| format!("Failed to initialize model manager: {}", e))?;
            }
        }

        let manager_lock = engine.summary_models().0.lock().await;
        manager_lock
            .as_ref()
            .ok_or_else(|| "Model manager not initialized".to_string())?
            .clone()
    };

    let refresh_scan = refresh.unwrap_or(false);
    let ready = manager.is_model_ready(&model_name, refresh_scan).await;

    log::info!(
        "Model '{}' ready check (refresh={}): {}",
        model_name,
        refresh_scan,
        ready
    );

    Ok(ready)
}

/// Check if a model is ready to use
#[tauri::command]
pub async fn builtin_ai_is_model_ready(
    engine: State<'_, Arc<Engine>>,
    model_name: String,
    refresh: Option<bool>,  // NEW: Optional refresh parameter
) -> Result<bool, String> {
    builtin_ai_is_model_ready_impl(&engine, model_name, refresh).await
}

async fn builtin_ai_get_available_summary_model_impl(
    engine: &Engine,
) -> Result<Option<String>, String> {
    let manager = {
        // Ensure manager is initialized
        {
            let manager_lock = engine.summary_models().0.lock().await;
            if manager_lock.is_none() {
                drop(manager_lock);
                init_model_manager(engine)
                    .await
                    .map_err(|e| format!("Failed to initialize model manager: {}", e))?;
            }
        }

        let manager_lock = engine.summary_models().0.lock().await;
        manager_lock
            .as_ref()
            .ok_or_else(|| "Model manager not initialized".to_string())?
            .clone()
    };

    // Force fresh scan to ensure accurate state
    manager
        .scan_models()
        .await
        .map_err(|e| format!("Failed to scan models: {}", e))?;

    // Get all available models
    let all_models = manager.list_models().await;

    // Find first available summary model
    let available = all_models
        .iter()
        .filter(|m| matches!(m.status, crate::summary::summary_engine::model_manager::ModelStatus::Available))
        .max_by_key(|m| summary_model_priority(&m.name))
        .map(|m| m.name.clone());

    log::info!("Available summary model check: {:?}", available);
    Ok(available)
}

/// Check if any summary model is available (for onboarding)
/// Returns the first available model name by priority, or None if no models exist
#[tauri::command]
pub async fn builtin_ai_get_available_summary_model(
    engine: State<'_, Arc<Engine>>,
) -> Result<Option<String>, String> {
    builtin_ai_get_available_summary_model_impl(&engine).await
}

// ============================================================================
// Startup Initialization & Utility Commands
// ============================================================================

pub async fn init_model_manager_at_startup<R: Runtime>(
    app: &AppHandle<R>,
) -> Result<(), String> {
    let models_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data dir: {}", e))?
        .join("models")
        .join("summary");

    let manager = ModelManager::new_with_models_dir(Some(models_dir))
        .map_err(|e| format!("Failed to create ModelManager: {}", e))?;

    manager
        .init()
        .await
        .map_err(|e| format!("Failed to initialize ModelManager: {}", e))?;

    let state: State<ModelManagerState> = app.state();
    let mut manager_lock = state.0.lock().await;
    *manager_lock = Some(Arc::new(manager));

    log::info!("ModelManager initialized at startup");
    Ok(())
}


/// Get recommended summary model based on platform and system RAM.
/// macOS → qwen3.5:4b
/// non-macOS + <8GB RAM → qwen3.5:2b
/// non-macOS + >=8GB RAM → qwen3.5:4b
#[tauri::command]
pub async fn builtin_ai_get_recommended_model() -> Result<String, String> {
    let recommended = get_recommended_summary_model_for_current_system()?;

    log::info!("Recommended summary model: {}", recommended);
    Ok(recommended.to_string())
}

/// Get total system RAM in gigabytes
fn get_system_ram_gb() -> Result<u64, String> {
    use sysinfo::System;

    let mut sys = System::new_all();
    sys.refresh_memory();

    let total_memory_bytes = sys.total_memory();
    let total_memory_gb = total_memory_bytes / (1024 * 1024 * 1024);

    Ok(total_memory_gb)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recommended_summary_model_uses_qwen2b_below_effective_16gb_floor() {
        assert_eq!(recommend_summary_model(true, 13), "qwen3.5:2b");
        assert_eq!(recommend_summary_model(false, 13), "qwen3.5:2b");
    }

    #[test]
    fn recommended_summary_model_uses_qwen4b_at_effective_16gb_floor() {
        assert_eq!(recommend_summary_model(true, 14), "qwen3.5:4b");
        assert_eq!(recommend_summary_model(false, 14), "qwen3.5:4b");
    }

    #[test]
    fn available_summary_model_priority_prefers_qwen_over_gemma() {
        assert!(summary_model_priority("qwen3.5:4b") > summary_model_priority("qwen3.5:2b"));
        assert!(summary_model_priority("qwen3.5:2b") > summary_model_priority("gemma3:4b"));
        assert!(summary_model_priority("gemma3:4b") > summary_model_priority("gemma3:1b"));
    }
}
