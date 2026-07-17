//! Apple on-device intelligence integration (Phase 1: availability probe).
//!
//! Wraps the `apple-helper` Swift sidecar, which exposes Apple's on-device
//! Speech + FoundationModels stack. Phase 1 only implements a stateless `probe`
//! that reports which capabilities are available; later phases add asset
//! management, transcription, and summarization over the same NDJSON protocol.

pub mod helper;
pub mod protocol;
pub mod resolver;
pub mod text_cleanup;

/// Report Apple STT/LLM availability. Always returns `Ok` with an HONEST
/// [`helper::ProbeStatus`] — the frontend renders availability from the struct,
/// including its `error` field when the stack is unavailable.
#[tauri::command]
pub async fn apple_probe() -> Result<helper::ProbeStatus, String> {
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
#[tauri::command]
pub async fn apple_ensure_assets(
    which: String,
    engine: tauri::State<'_, std::sync::Arc<crate::engine::Engine>>,
) -> Result<bool, String> {
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
