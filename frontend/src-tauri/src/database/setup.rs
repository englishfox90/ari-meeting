use log::info;
use tauri::{AppHandle, Manager};

use super::manager;

/// Initialize database on app startup
/// Handles first launch detection and conditional initialization
pub async fn initialize_database_on_startup(app: &AppHandle) -> Result<(), String> {
    // Check if this is the first launch (no database exists yet)
    let is_first_launch = manager::is_first_launch(app)
        .await
        .map_err(|e| format!("Failed to check first launch status: {}", e))?;

    if is_first_launch {
        info!("First launch detected - will notify window when ready");

        // Delay event emission to ensure window is ready and React listeners are registered
        let app_handle = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
            app_handle
                .state::<std::sync::Arc<crate::engine::Engine>>()
                .event_sink()
                .emit("first-launch-detected", ());
            info!("Emitted first-launch-detected after delay");
        });
    } else {
        // Normal flow - initialize database immediately
        let db_manager = manager::new_from_app_handle(app)
            .await
            .map_err(|e| format!("Failed to initialize database manager: {}", e))?;

        // Install the DB into the engine — the single DB owner now (AppState is gone).
        let engine = app
            .try_state::<std::sync::Arc<crate::engine::Engine>>()
            .ok_or_else(|| "Engine not managed; cannot initialize database".to_string())?;
        engine.set_db(db_manager).await;
        info!("Database initialized successfully");
    }

    Ok(())
}
