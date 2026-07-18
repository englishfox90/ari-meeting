//! Engine-touching layer for the embedding-model catalog + downloader — `_impl` fns for
//! the host's `#[tauri::command]` shims (`frontend/src-tauri/src/recall/embed_models.rs`),
//! moved during the ari-engine carve (Stage B1, `docs/plans/ari-engine-carve.md`).
//!
//! The catalog + `EmbedModelManager` + `EmbedModelManagerState` already live in
//! `crate::embed_models` (moved earlier in Stage B1, fully Tauri-free); this module is
//! the `Engine`-touching half: `ensure_manager` (lazily inits the manager on `Engine`'s
//! deferred sub-state) and the four command bodies.

pub use crate::embed_models::{
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
pub async fn recall_embedder_list_models_impl(engine: &Engine) -> Result<Vec<EmbedModelInfo>, String> {
    let manager = ensure_manager(engine).await?;
    manager.scan().await;
    Ok(manager.list_models().await)
}

/// Download an embedding model; emits `recall-embedder-download-progress`.
pub async fn recall_embedder_download_model_impl(
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

/// Cancel an in-flight embedding-model download.
pub async fn recall_embedder_cancel_download_impl(
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

/// Delete a downloaded embedding model file.
pub async fn recall_embedder_delete_model_impl(
    engine: &Engine,
    model_name: String,
) -> Result<(), String> {
    let manager = ensure_manager(engine).await?;
    manager.delete_model(&model_name).await.map_err(|e| e.to_string())
}
