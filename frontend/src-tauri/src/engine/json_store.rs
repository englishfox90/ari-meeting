//! Headless replacement for the two engine-side uses of the Tauri **store
//! plugin** (`onboarding-status.json`, `recording_preferences.json`).
//!
//! The plugin resolves a bare filename against `BaseDirectory::AppData`
//! (`tauri-plugin-store` `resolve_store_path` → `app.path().resolve(path,
//! BaseDirectory::AppData)`) and persists a flat `HashMap<String, JsonValue>`
//! as compact JSON (`serde_json::to_vec`) via `fs::write`. This module
//! reproduces that exact file location (`<app_data>/<file_name>`) and on-disk
//! shape, so existing users' JSON files load unchanged — no migration step,
//! no format change. Host-side stores (`tray.rs` app-preferences,
//! `notch/bridge.rs` settings) stay on the plugin; this is only for the two
//! engine-side stores that needed a Tauri-free home to leave the host.
use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;

use super::paths::Paths;

fn store_path(paths: &Paths, file_name: &str) -> PathBuf {
    paths.app_data.join(file_name)
}

/// Read the full key/value map from `<app_data>/<file_name>`. Missing or
/// unparsable files yield an empty map (mirrors the plugin's graceful
/// "no store yet" behavior — never an error the caller must handle).
fn read_store(paths: &Paths, file_name: &str) -> HashMap<String, Value> {
    let path = store_path(paths, file_name);
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => HashMap::new(),
    }
}

/// Persist the full key/value map to `<app_data>/<file_name>`, creating the
/// parent directory if needed (same as the plugin's `save()`).
fn write_store(paths: &Paths, file_name: &str, map: &HashMap<String, Value>) -> Result<()> {
    let path = store_path(paths, file_name);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create store dir {:?}", parent))?;
    }
    let bytes = serde_json::to_vec(map).context("failed to serialize store")?;
    std::fs::write(&path, bytes).with_context(|| format!("failed to write store {:?}", path))?;
    Ok(())
}

/// Get one key from a store file, deserialized into `T`. Returns `None` if
/// the file, or the key within it, is absent or fails to deserialize.
pub fn get<T: DeserializeOwned>(paths: &Paths, file_name: &str, key: &str) -> Option<T> {
    let map = read_store(paths, file_name);
    map.get(key)
        .and_then(|v| serde_json::from_value(v.clone()).ok())
}

/// True if `key` is present in the store file at all (distinguishes "never
/// saved" from "saved with default values", same as the plugin's `.get()`
/// returning `Some`/`None`).
pub fn has_key(paths: &Paths, file_name: &str, key: &str) -> bool {
    read_store(paths, file_name).contains_key(key)
}

/// Set one key in a store file and persist the whole map to disk
/// (read-modify-write, matching `store.set(key, value); store.save();`).
pub fn set<T: Serialize>(paths: &Paths, file_name: &str, key: &str, value: &T) -> Result<()> {
    let mut map = read_store(paths, file_name);
    let value = serde_json::to_value(value).context("failed to serialize store value")?;
    map.insert(key.to_string(), value);
    write_store(paths, file_name, &map)
}

/// Delete one key from a store file and persist the remainder to disk
/// (matching `store.delete(key); store.save();`).
pub fn delete(paths: &Paths, file_name: &str, key: &str) -> Result<()> {
    let mut map = read_store(paths, file_name);
    map.remove(key);
    write_store(paths, file_name, &map)
}
