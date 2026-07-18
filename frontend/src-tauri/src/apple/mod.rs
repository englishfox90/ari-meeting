//! Apple on-device intelligence integration (Phase 1: availability probe).
//!
//! The pure logic (NDJSON protocol, sidecar resolver, helper client, text
//! cleanup) now lives in `ari-engine::apple`; this module is a thin re-export
//! shim (so `crate::apple::*` keeps resolving for existing callers) plus the
//! `#[tauri::command]` shims that stay host-side.

pub use ari_engine::apple::*;

/// Report Apple STT/LLM availability. Always returns `Ok` with an HONEST
/// [`helper::ProbeStatus`] — the frontend renders availability from the struct,
/// including its `error` field when the stack is unavailable.
#[tauri::command]
pub async fn apple_probe() -> Result<helper::ProbeStatus, String> {
    ari_engine::apple::apple_probe_impl().await
}

/// Ensure Apple on-device `which` assets (e.g. `"speech"`) are installed,
/// emitting an `apple-assets-progress` event (`{ fraction }`) for every real
/// progress tick the sidecar streams. Resolves to whether the assets are now
/// installed, or an honest error on failure (No-Fake-State).
#[tauri::command]
pub async fn apple_ensure_assets(
    which: String,
    engine: tauri::State<'_, std::sync::Arc<ari_engine::engine::Engine>>,
) -> Result<bool, String> {
    ari_engine::apple::apple_ensure_assets_impl(which, &engine).await
}
