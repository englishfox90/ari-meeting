//! Apple on-device intelligence integration (Phase 1: availability probe).
//!
//! Wraps the `apple-helper` Swift sidecar, which exposes Apple's on-device
//! Speech + FoundationModels stack. Phase 1 only implements a stateless `probe`
//! that reports which capabilities are available; later phases add asset
//! management, transcription, and summarization over the same NDJSON protocol.
//!
//! Tauri-free: the `#[tauri::command]` shims (`apple_probe`, `apple_ensure_assets`)
//! stay in the host (`frontend/src-tauri/src/apple/mod.rs`); this module holds the
//! pure logic plus the `*_impl` fns those shims call, per the ari-engine carve's
//! per-service migration recipe (`docs/plans/ari-engine-carve.md`).

pub mod helper;
pub mod protocol;
pub mod resolver;
pub mod text_cleanup;

use crate::engine::Engine;

/// Report Apple STT/LLM availability. Always returns `Ok` with an HONEST
/// [`helper::ProbeStatus`] — the frontend renders availability from the struct,
/// including its `error` field when the stack is unavailable.
pub async fn apple_probe_impl() -> Result<helper::ProbeStatus, String> {
    Ok(helper::probe().await)
}

/// Payload of the `apple-assets-progress` event: a single real download-progress
/// tick. camelCase on the wire (`{ fraction }`) — the frontend depends on this.
#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct AppleAssetsProgress {
    fraction: f64,
}

/// Ensure Apple on-device `which` assets (e.g. `"speech"`) are installed,
/// emitting an `apple-assets-progress` event (`{ fraction }`) for every real
/// progress tick the sidecar streams. Resolves to whether the assets are now
/// installed, or an honest error on failure (No-Fake-State).
pub async fn apple_ensure_assets_impl(which: String, engine: &Engine) -> Result<bool, String> {
    // Owned sink: moved into the 'static progress callback, which can't
    // borrow from `&Engine`.
    let sink = engine.event_sink();
    helper::ensure_assets(
        &which,
        move |fraction| {
            sink.emit("apple-assets-progress", AppleAssetsProgress { fraction });
        },
        None,
    )
    .await
}
