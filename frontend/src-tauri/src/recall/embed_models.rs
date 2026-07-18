//! Embedding-model catalog + a dedicated downloader/manager for the optional
//! nomic-embed-text GGUF. Fully additive and independent of the summary model catalog and
//! its `ModelManager` (they must never interfere), so switching or downloading an embedding
//! model can never touch a summary download or the summary sidecar.
//!
//! Downloaded models live under `app_data_dir/models/embeddings/`. The one catalog entry is
//! nomic-embed-text v1.5 (GGUF, mean-pooled, 768-d), run through the dedicated embed sidecar
//! instance in `embed_runtime.rs`.
//!
//! The catalog + `EmbedModelManager` + `EmbedModelManagerState` moved to
//! `ari-engine::embed_models` (Phase 1.5 carve, Stage B1) — they're Tauri-free. What stays
//! here is the `Engine`-touching layer: `ensure_manager` and the `#[tauri::command]` shims.

pub use ari_engine::embed_models::{
    embeddings_directory, get_available_embed_models, get_default_embed_model,
    get_embed_model_by_name, get_embed_model_path, DownloadProgress, EmbedModelDef,
    EmbedModelInfo, EmbedModelManager, EmbedModelManagerState, EmbedModelStatus,
};

use crate::engine::Engine;

async fn ensure_manager(engine: &Engine) -> Result<std::sync::Arc<EmbedModelManager>, String> {
    {
        let lock = engine.embed_models().0.lock().await;
        if let Some(m) = lock.as_ref() {
            return Ok(m.clone());
        }
    }
    let dir = engine.paths().embedding_models();
    let manager = EmbedModelManager::new_with_dir(dir);
    manager
        .init()
        .await
        .map_err(|e| format!("Failed to init embed model manager: {}", e))?;
    let arc = std::sync::Arc::new(manager);
    let mut lock = engine.embed_models().0.lock().await;
    *lock = Some(arc.clone());
    Ok(arc)
}

/// List embedding models with download status.
async fn recall_embedder_list_models_impl(engine: &Engine) -> Result<Vec<EmbedModelInfo>, String> {
    let manager = ensure_manager(engine).await?;
    manager.scan().await;
    Ok(manager.list_models().await)
}

#[tauri::command]
pub async fn recall_embedder_list_models(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<EmbedModelInfo>, String> {
    recall_embedder_list_models_impl(&engine).await
}

/// Download an embedding model; emits `recall-embedder-download-progress`.
async fn recall_embedder_download_model_impl(
    engine: &Engine,
    model_name: String,
) -> Result<(), String> {
    let manager = ensure_manager(engine).await?;

    // Owned sink for the 'static progress callback (a borrow of &Engine can't
    // escape into the callback). `sink` for the post-download emits below;
    // `sink_cb` is moved into the closure.
    let sink = engine.event_sink();
    let sink_cb = sink.clone();
    let model_for_cb = model_name.clone();
    let on_progress = move |p: DownloadProgress| {
        sink_cb.emit(
            "recall-embedder-download-progress",
            serde_json::json!({
                "model": model_for_cb,
                "progress": p.percent,
                "downloaded_mb": p.downloaded_mb,
                "total_mb": p.total_mb,
                "speed_mbps": p.speed_mbps,
                "status": "downloading"
            }),
        );
    };

    match manager.download_detailed(&model_name, on_progress).await {
        Ok(()) => {
            sink.emit(
                "recall-embedder-download-progress",
                serde_json::json!({
                    "model": model_name,
                    "progress": 100,
                    "downloaded_mb": 0,
                    "total_mb": 0,
                    "speed_mbps": 0,
                    "status": "completed"
                }),
            );
            Ok(())
        }
        Err(e) => {
            let msg = e.to_string();
            if !msg.starts_with("CANCELLED:") {
                sink.emit(
                    "recall-embedder-download-progress",
                    serde_json::json!({
                        "model": model_name,
                        "progress": 0,
                        "downloaded_mb": 0,
                        "total_mb": 0,
                        "speed_mbps": 0,
                        "status": "error",
                        "error": msg
                    }),
                );
            }
            Err(msg)
        }
    }
}

#[tauri::command]
pub async fn recall_embedder_download_model(
    model_name: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    recall_embedder_download_model_impl(&engine, model_name).await
}

/// Cancel an in-flight embedding-model download.
async fn recall_embedder_cancel_download_impl(
    engine: &Engine,
    model_name: Option<String>,
) -> Result<(), String> {
    let manager = ensure_manager(engine).await?;
    // The frontend cancels without naming a model (there's only one); default to it.
    let model_name = model_name.unwrap_or_else(|| get_default_embed_model().name);
    manager.cancel_download(&model_name).await;
    engine.event_sink().emit(
        "recall-embedder-download-progress",
        serde_json::json!({
            "model": model_name,
            "progress": 0,
            "status": "cancelled"
        }),
    );
    Ok(())
}

#[tauri::command]
pub async fn recall_embedder_cancel_download(
    model_name: Option<String>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    recall_embedder_cancel_download_impl(&engine, model_name).await
}

/// Delete a downloaded embedding model file.
async fn recall_embedder_delete_model_impl(
    engine: &Engine,
    model_name: String,
) -> Result<(), String> {
    let manager = ensure_manager(engine).await?;
    manager.delete_model(&model_name).await.map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn recall_embedder_delete_model(
    model_name: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    recall_embedder_delete_model_impl(&engine, model_name).await
}
