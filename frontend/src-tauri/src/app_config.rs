// App-level configuration (F3 support) — small, file-backed global settings that aren't
// per-person or per-meeting. Currently just the owner's organization, which is company-wide
// (this is a private single-org app) and therefore does NOT belong on each person record.
//
// Stored as JSON at `<app_config_dir>/ari.config.json` so it's user-editable by hand and not
// hardcoded. A missing/invalid file yields the default (organization = "Arivo"); the file is
// (re)written on first read and on set so the user has a concrete file to edit.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

/// Fallback organization when no config file exists yet. Not a hardcoded product value —
/// just the default seed written to the editable config file on first run.
const DEFAULT_ORGANIZATION: &str = "Arivo";

const CONFIG_FILE_NAME: &str = "ari.config.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub organization: String,
}

impl Default for AppConfig {
    fn default() -> Self {
        AppConfig {
            organization: DEFAULT_ORGANIZATION.to_string(),
        }
    }
}

fn config_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_config_dir()
        .map_err(|e| format!("Could not resolve app config dir: {}", e))?;
    Ok(dir.join(CONFIG_FILE_NAME))
}

/// Read the config, falling back to default (and writing it out) when the file is absent or
/// unreadable. Never errors on a missing file — only on a genuine inability to resolve the
/// config directory.
pub fn load(app: &AppHandle) -> Result<AppConfig, String> {
    let path = config_path(app)?;
    match std::fs::read_to_string(&path) {
        Ok(contents) => match serde_json::from_str::<AppConfig>(&contents) {
            Ok(cfg) => Ok(cfg),
            Err(e) => {
                log::warn!("ari.config.json is invalid ({}); using defaults", e);
                let cfg = AppConfig::default();
                let _ = write(app, &cfg);
                Ok(cfg)
            }
        },
        Err(_) => {
            // First run (or file removed): seed the editable file with defaults.
            let cfg = AppConfig::default();
            let _ = write(app, &cfg);
            Ok(cfg)
        }
    }
}

fn write(app: &AppHandle, cfg: &AppConfig) -> Result<(), String> {
    let path = config_path(app)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Could not create app config dir: {}", e))?;
    }
    let json = serde_json::to_string_pretty(cfg)
        .map_err(|e| format!("Could not serialize app config: {}", e))?;
    std::fs::write(&path, json).map_err(|e| format!("Could not write ari.config.json: {}", e))
}

#[tauri::command]
pub async fn app_config_get(app: AppHandle) -> Result<AppConfig, String> {
    load(&app)
}

#[tauri::command]
pub async fn app_config_set_organization(
    app: AppHandle,
    organization: String,
) -> Result<AppConfig, String> {
    let cfg = AppConfig {
        organization: organization.trim().to_string(),
    };
    write(&app, &cfg)?;
    Ok(cfg)
}
