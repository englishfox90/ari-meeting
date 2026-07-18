//! Tauri-side resolution for `ari_engine::database::manager::DatabaseManager`.
//!
//! The pure `DatabaseManager` (pool, migrations, transactions, cleanup) lives in
//! `ari_engine::database::manager` — see that module's docs. The 3 functions
//! here resolve `app_data_dir` from a `tauri::AppHandle` and bootstrap the DB
//! *before* the `Engine` exists, so they stay host-side as free functions
//! rather than inherent methods (Rust's orphan rule forbids adding inherent
//! impls to a foreign type, now that `DatabaseManager` is defined in another
//! crate) — the same shape as `engine::paths::from_tauri`.

use sqlx::Result;
use std::fs;
use tauri::Manager;

pub use ari_engine::database::manager::DatabaseManager;

// NOTE: So for the first time users they needs to start the application
// after they can just delete the existing .sqlite file and then copy the existing .db file to
// the current app dir, So the system detects legacy db and copy it and starts with that data
// (Newly created .sqlite with the copied content from .db)
pub async fn new_from_app_handle(app_handle: &tauri::AppHandle) -> Result<DatabaseManager> {
    // Resolve the app's data directory
    let app_data_dir = app_handle
        .path()
        .app_data_dir()
        .expect("failed to get app data dir");
    if !app_data_dir.exists() {
        fs::create_dir_all(&app_data_dir).map_err(|e| sqlx::Error::Io(e))?;
    }

    // Define database paths
    let tauri_db_path = app_data_dir
        .join("meeting_minutes.sqlite")
        .to_string_lossy()
        .to_string();
    // Legacy backend DB path (for auto-migration if exists)
    let backend_db_path = app_data_dir
        .join("meeting_minutes.db")
        .to_string_lossy()
        .to_string();

    // WAL file paths for defensive cleanup
    let wal_path = app_data_dir.join("meeting_minutes.sqlite-wal");
    let shm_path = app_data_dir.join("meeting_minutes.sqlite-shm");

    log::info!("Tauri DB path: {}", tauri_db_path);
    log::info!("Legacy backend DB path: {}", backend_db_path);

    // Try to open database with defensive WAL handling
    match DatabaseManager::new(&tauri_db_path, &backend_db_path).await {
        Ok(db_manager) => {
            log::info!("Database opened successfully");
            Ok(db_manager)
        }
        Err(e) => {
            // Check if error is due to corrupted WAL file
            let error_msg = e.to_string();
            if error_msg.contains("malformed") || error_msg.contains("corrupt") {
                log::warn!("Database appears corrupted, likely due to orphaned WAL file. Attempting recovery...");
                log::warn!("Error details: {}", error_msg);

                // Delete potentially corrupted WAL/SHM files
                if wal_path.exists() {
                    match fs::remove_file(&wal_path) {
                        Ok(_) => log::info!("Removed orphaned WAL file: {:?}", wal_path),
                        Err(e) => log::warn!("Failed to remove WAL file: {}", e),
                    }
                }
                if shm_path.exists() {
                    match fs::remove_file(&shm_path) {
                        Ok(_) => log::info!("Removed orphaned SHM file: {:?}", shm_path),
                        Err(e) => log::warn!("Failed to remove SHM file: {}", e),
                    }
                }

                // Retry connection without WAL files
                log::info!("Retrying database connection after WAL cleanup...");
                match DatabaseManager::new(&tauri_db_path, &backend_db_path).await {
                    Ok(db_manager) => {
                        log::info!("Database opened successfully after WAL recovery");
                        Ok(db_manager)
                    }
                    Err(retry_err) => {
                        log::error!("Database connection failed even after WAL cleanup: {}", retry_err);
                        Err(retry_err)
                    }
                }
            } else {
                // Not a WAL-related error, propagate original error
                log::error!("Database connection failed: {}", error_msg);
                Err(e)
            }
        }
    }
}

/// Check if this is the first launch (sqlite database doesn't exist yet)
pub async fn is_first_launch(app_handle: &tauri::AppHandle) -> Result<bool> {
    let app_data_dir = app_handle
        .path()
        .app_data_dir()
        .expect("failed to get app data dir");

    let tauri_db_path = app_data_dir.join("meeting_minutes.sqlite");

    Ok(!tauri_db_path.exists())
}

/// Import a legacy database from the specified path and initialize
pub async fn import_legacy_database(
    app_handle: &tauri::AppHandle,
    legacy_db_path: &str,
) -> Result<DatabaseManager> {
    let app_data_dir = app_handle
        .path()
        .app_data_dir()
        .expect("failed to get app data dir");

    if !app_data_dir.exists() {
        fs::create_dir_all(&app_data_dir).map_err(|e| sqlx::Error::Io(e))?;
    }

    // Copy legacy database to app data directory as meeting_minutes.db
    let target_legacy_path = app_data_dir.join("meeting_minutes.db");
    log::info!(
        "Copying legacy database from {} to {}",
        legacy_db_path,
        target_legacy_path.display()
    );

    fs::copy(legacy_db_path, &target_legacy_path).map_err(|e| sqlx::Error::Io(e))?;

    // Now use the standard initialization which will detect and migrate the legacy db
    new_from_app_handle(app_handle).await
}
