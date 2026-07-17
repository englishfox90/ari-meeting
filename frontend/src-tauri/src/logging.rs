//! Rolling file logging (additive).
//!
//! The app historically only had `env_logger` writing to stderr, which is
//! discarded when the bundle is launched via `open` (e.g. `pnpm run app:local`).
//! That made runtime troubleshooting (permissions, audio taps, summary calls)
//! impossible after the fact.
//!
//! This module registers `tauri-plugin-log` with a rotating file target in the
//! OS log dir (`~/Library/Logs/com.meetily.ai/` on macOS) plus stdout, and
//! prunes files older than `RETENTION_DAYS` on startup — giving a rolling
//! window of logs for both dev/testing and production support.

use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime};

use tauri_plugin_log::{Builder as LogBuilder, RotationStrategy, Target, TargetKind};

/// How many days of logs to retain. Older files are pruned on startup.
pub const RETENTION_DAYS: u64 = 5;

/// Base file name (without extension) for the rolling log in the app log dir.
const LOG_FILE_NAME: &str = "ari";

/// Build the `tauri-plugin-log` plugin: a rotating file in the app log dir AND
/// stdout, so both `open`-launched bundles and terminal runs persist logs.
///
/// This becomes the global `log` logger, so `env_logger::init()` must NOT also
/// run (see `main.rs`) — two loggers cannot both claim the global slot.
pub fn plugin() -> tauri::plugin::TauriPlugin<tauri::Wry> {
    LogBuilder::new()
        .target(Target::new(TargetKind::Stdout))
        .target(Target::new(TargetKind::LogDir {
            file_name: Some(LOG_FILE_NAME.to_string()),
        }))
        // Size-based rotation keeps a single file from growing unbounded; the
        // startup prune (below) enforces the real time-based retention window.
        .rotation_strategy(RotationStrategy::KeepAll)
        .max_file_size(10_000_000) // 10 MB per file before rotating
        .level(log::LevelFilter::Info)
        // Audio capture is the most common thing we need to debug (permissions,
        // Core Audio taps, device changes), so keep it verbose.
        .level_for("app_lib::audio", log::LevelFilter::Debug)
        .build()
}

/// Delete `*.log` files older than `RETENTION_DAYS` in `dir`. Best-effort:
/// any I/O error is ignored so logging setup never blocks app startup.
pub fn prune_old_logs(dir: &Path) {
    let cutoff = match SystemTime::now()
        .checked_sub(Duration::from_secs(RETENTION_DAYS * 24 * 60 * 60))
    {
        Some(cutoff) => cutoff,
        None => return,
    };

    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return, // dir may not exist yet on first launch — that's fine
    };

    let mut pruned = 0u32;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("log") {
            continue;
        }
        if let Ok(modified) = entry.metadata().and_then(|meta| meta.modified()) {
            if modified < cutoff && fs::remove_file(&path).is_ok() {
                pruned += 1;
            }
        }
    }

    if pruned > 0 {
        log::info!("🧹 Pruned {} log file(s) older than {} days", pruned, RETENTION_DAYS);
    }
}
