//! Tauri-side resolution of `ari_engine::engine::Paths`.
//!
//! `Paths` itself (the struct + its subdirectory helpers) lives in
//! `ari_engine::engine::paths` (pure `PathBuf` joins, no Tauri). Its fields are
//! all `pub`, so this free function constructs it via a struct literal instead
//! of an inherent `from_tauri` method — Rust's orphan rule forbids an inherent
//! impl on a foreign type, so the Tauri-resolving constructor moved here as a
//! plain function rather than staying a method on `Paths`.
pub use ari_engine::engine::Paths;
use tauri::{AppHandle, Manager, Runtime};

/// Resolve every directory from the Tauri host, once, at engine startup.
/// Stage A only — the headless daemon resolves these without an AppHandle.
pub fn from_tauri<R: Runtime>(app: &AppHandle<R>) -> anyhow::Result<Paths> {
    let p = app.path();
    Ok(Paths {
        app_data: p.app_data_dir()?,
        app_log: p.app_log_dir()?,
        app_config: p.app_config_dir()?,
        resource: p.resource_dir()?,
    })
}
