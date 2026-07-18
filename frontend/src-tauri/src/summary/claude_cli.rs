//! Claude CLI provider — thin `#[tauri::command]` shim. The pure logic
//! (binary resolution, subprocess invocation) now lives in
//! `ari_engine::summary::claude_cli`, per the ari-engine carve's per-service
//! migration recipe (`docs/plans/ari-engine-carve.md`).

pub use ari_engine::summary::claude_cli::*;

/// Tauri command: report whether the local Claude CLI is available.
#[tauri::command]
pub async fn claude_cli_detect() -> Result<ClaudeCliStatus, String> {
    tauri::async_runtime::spawn_blocking(detect_claude_cli)
        .await
        .map_err(|e| format!("Claude CLI detection failed: {}", e))
}
