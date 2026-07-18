// Headless (Tauri-free) half of the built-in AI summary engine's model management.
// Moved from frontend/src-tauri/src/summary/summary_engine/{model_manager,models}.rs
// (Phase 1.5 carve, Stage B1). The host crate re-exports these paths so existing
// `crate::summary::summary_engine::...` references keep resolving.

pub mod model_manager;
pub mod models;

use std::sync::Arc;

use tokio::sync::Mutex;

pub use model_manager::{DownloadProgress, ModelInfo, ModelManager, ModelStatus};
pub use models::{get_available_models, get_default_model, get_model_by_name, ModelDef};

/// Global model manager instance. Just an `Arc<Mutex<Option<Arc<ModelManager>>>>` newtype —
/// zero Tauri coupling itself, but historically lived alongside the `#[tauri::command]`s in
/// the host's `summary_engine/commands.rs`. Moved here so `ari-engine` owns the manager it wraps;
/// the host still constructs/consumes it via `Engine`.
pub struct ModelManagerState(pub Arc<Mutex<Option<Arc<ModelManager>>>>);
