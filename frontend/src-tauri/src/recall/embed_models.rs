//! Embedding-model catalog + a dedicated downloader/manager for the optional
//! nomic-embed-text GGUF. The catalog + `EmbedModelManager` + `EmbedModelManagerState`
//! moved to `ari-engine::embed_models`, and the `Engine`-touching `ensure_manager` +
//! `*_impl` fns moved to `ari-engine::recall::embed_models` (Phase 1.5 carve, Stage B1).
//! What stays here is the thin `#[tauri::command]` surface, per the ari-engine carve's
//! per-service migration recipe (`docs/plans/ari-engine-carve.md`).

use ari_engine::recall::embed_models as engine_embed_models;

pub use ari_engine::embed_models::{
    embeddings_directory, get_available_embed_models, get_default_embed_model,
    get_embed_model_by_name, get_embed_model_path, DownloadProgress, EmbedModelDef,
    EmbedModelInfo, EmbedModelManager, EmbedModelManagerState, EmbedModelStatus,
};

use crate::engine::Engine;

/// List embedding models with download status.
#[tauri::command]
pub async fn recall_embedder_list_models(
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<Vec<EmbedModelInfo>, String> {
    engine_embed_models::recall_embedder_list_models_impl(&engine).await
}

/// Download an embedding model; emits `recall-embedder-download-progress`.
#[tauri::command]
pub async fn recall_embedder_download_model(
    model_name: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_embed_models::recall_embedder_download_model_impl(&engine, model_name).await
}

/// Cancel an in-flight embedding-model download.
#[tauri::command]
pub async fn recall_embedder_cancel_download(
    model_name: Option<String>,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_embed_models::recall_embedder_cancel_download_impl(&engine, model_name).await
}

/// Delete a downloaded embedding model file.
#[tauri::command]
pub async fn recall_embedder_delete_model(
    model_name: String,
    engine: tauri::State<'_, std::sync::Arc<Engine>>,
) -> Result<(), String> {
    engine_embed_models::recall_embedder_delete_model_impl(&engine, model_name).await
}
