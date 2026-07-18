use anyhow::Result;

pub use ari_engine::whisper_engine::ParallelProcessorState;

pub async fn get_system_resources_impl(
    engine: &crate::engine::Engine,
) -> Result<serde_json::Value, String> {
    engine.parallel().system_monitor.refresh_system_info()
        .await
        .map_err(|e| format!("Failed to refresh system info: {}", e))?;

    let resources = engine.parallel().system_monitor.get_current_resources()
        .await
        .map_err(|e| format!("Failed to get system resources: {}", e))?;

    serde_json::to_value(resources)
        .map_err(|e| format!("Failed to serialize resources: {}", e))
}

#[tauri::command]
pub async fn get_system_resources(
    engine: tauri::State<'_, std::sync::Arc<crate::engine::Engine>>,
) -> Result<serde_json::Value, String> {
    get_system_resources_impl(&engine).await
}
