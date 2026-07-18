//! Dedicated `llama-helper` instance for embeddings, kept entirely separate from the summary
//! sidecar so the two never thrash each other's loaded model.
//!
//! The summary path (`summary::summary_engine::client`) owns its own global `SidecarManager`
//! and restarts that process whenever the summary model changes. Embeddings must not ride on
//! it — a single Ask-Meetings query would evict the multi-GB summary model and reload it. So
//! we spawn a SECOND `SidecarManager` here, pinned to the nomic GGUF, addressed through its own
//! global. Same helper binary, independent child process, independent loaded model.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use tokio::sync::Mutex;

use crate::recall::embed_models::{embeddings_directory, get_default_embed_model};
use crate::summary_engine::sidecar::SidecarManager;

/// Timeout for one embed exchange (model load on first call can take a few seconds).
const EMBED_TIMEOUT_SECS: u64 = 120;

lazy_static::lazy_static! {
    /// Global handle to the embeddings-only sidecar. Distinct from the summary
    /// `SIDECAR_MANAGER`; the two never share a process.
    static ref EMBED_SIDECAR_MANAGER: Arc<Mutex<Option<Arc<SidecarManager>>>> =
        Arc::new(Mutex::new(None));
}

/// Resolve the on-disk path of the default embedding model, or `None` if not downloaded.
fn resolve_model_path() -> Result<PathBuf, String> {
    let app_data_dir = crate::recall::embedding::app_data_dir()
        .ok_or_else(|| "app data dir not initialized".to_string())?;
    let def = get_default_embed_model();
    let path = embeddings_directory(&app_data_dir).join(&def.gguf_file);
    if !path.exists() {
        return Err(format!(
            "embedding model '{}' is not downloaded ({})",
            def.name,
            path.display()
        ));
    }
    Ok(path)
}

/// Embed a batch of texts through the dedicated embed sidecar. Returns one L2-normalized
/// vector per input, in order. `Err` when the model isn't downloaded or the sidecar fails —
/// callers degrade to lexical-only.
pub async fn embed_batch(texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }

    let model_path = resolve_model_path()?;

    // Get or lazily create the embed-only manager (own app-data dir just for binary resolution).
    let manager = {
        let app_data_dir = crate::recall::embedding::app_data_dir()
            .ok_or_else(|| "app data dir not initialized".to_string())?;
        let mut guard = EMBED_SIDECAR_MANAGER.lock().await;
        if guard.is_none() {
            let new_manager = SidecarManager::new(app_data_dir)
                .map_err(|e| format!("failed to create embed sidecar manager: {}", e))?;
            *guard = Some(Arc::new(new_manager));
        }
        guard.clone().unwrap()
    };

    manager
        .ensure_running(model_path.clone())
        .await
        .map_err(|e| format!("failed to start embed sidecar: {}", e))?;

    let request = serde_json::json!({
        "type": "embed",
        "texts": texts,
        "model_path": model_path.to_string_lossy(),
        "normalize": true,
    })
    .to_string();

    let response_json = manager
        .send_request(request, Duration::from_secs(EMBED_TIMEOUT_SECS))
        .await
        .map_err(|e| format!("embed sidecar request failed: {}", e))?;

    let value: Value = serde_json::from_str(&response_json)
        .map_err(|e| format!("failed to parse embed response: {} ({})", e, response_json))?;

    match value.get("type").and_then(|t| t.as_str()) {
        Some("embeddings") => {
            let vectors = value
                .get("vectors")
                .cloned()
                .ok_or_else(|| "embeddings response missing 'vectors'".to_string())?;
            let vectors: Vec<Vec<f32>> = serde_json::from_value(vectors)
                .map_err(|e| format!("failed to decode embedding vectors: {}", e))?;
            if vectors.len() != texts.len() {
                return Err(format!(
                    "embed count mismatch: got {} vectors for {} inputs",
                    vectors.len(),
                    texts.len()
                ));
            }
            Ok(vectors)
        }
        Some("error") => Err(format!(
            "embed sidecar error: {}",
            value
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("unknown")
        )),
        Some("response") => Err(format!(
            "embed sidecar returned generation response instead of embeddings: {}",
            value
                .get("error")
                .and_then(|m| m.as_str())
                .unwrap_or("no error field")
        )),
        other => Err(format!("unexpected embed response type: {:?}", other)),
    }
}

/// Force-shutdown the embed sidecar (app exit). Best-effort; safe if never started.
pub async fn shutdown() {
    let manager_opt = {
        let mut guard = EMBED_SIDECAR_MANAGER.lock().await;
        guard.take()
    };
    if let Some(manager) = manager_opt {
        let _ = manager.shutdown().await;
    }
}
