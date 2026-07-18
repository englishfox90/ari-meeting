// Headless (Tauri-free) half of the built-in AI summary engine's model management.
// Moved from frontend/src-tauri/src/summary/summary_engine/{model_manager,models}.rs
// (Phase 1.5 carve, Stage B1). `client.rs`/`sidecar.rs` (the sidecar-driving
// high-level API + process lifecycle manager) joined them in the `summary` module
// move — zero Tauri coupling of their own, just raw `tokio::process`. The host
// crate re-exports these paths so existing `crate::summary::summary_engine::...`
// references keep resolving; the Tauri commands in
// `frontend/src-tauri/src/summary/summary_engine/commands.rs` stay host-side.

pub mod client;
pub mod model_manager;
pub mod models;
pub mod sidecar;

use std::sync::Arc;

use tokio::sync::Mutex;

pub use client::{
    force_shutdown_sidecar, generate_with_builtin, generate_with_builtin_stream,
    init_sidecar_manager, is_sidecar_healthy, shutdown_sidecar_gracefully,
};
pub use model_manager::{DownloadProgress, ModelInfo, ModelManager, ModelStatus};
pub use models::{get_available_models, get_default_model, get_model_by_name, ModelDef};
pub use sidecar::SidecarManager;

/// Global model manager instance. Just an `Arc<Mutex<Option<Arc<ModelManager>>>>` newtype —
/// zero Tauri coupling itself, but historically lived alongside the `#[tauri::command]`s in
/// the host's `summary_engine/commands.rs`. Moved here so `ari-engine` owns the manager it wraps;
/// the host still constructs/consumes it via `Engine`.
pub struct ModelManagerState(pub Arc<Mutex<Option<Arc<ModelManager>>>>);
