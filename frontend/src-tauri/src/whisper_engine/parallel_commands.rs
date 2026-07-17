use tauri::State;
use std::sync::Arc;
use tokio::sync::RwLock;
use anyhow::Result;

use crate::whisper_engine::{
    ParallelProcessor, SystemMonitor,
};

// Global state for parallel processor
pub struct ParallelProcessorState {
    pub processor: Arc<RwLock<Option<ParallelProcessor>>>,
    pub system_monitor: Arc<SystemMonitor>,
}

impl ParallelProcessorState {
    pub fn new() -> Self {
        Self {
            processor: Arc::new(RwLock::new(None)),
            system_monitor: Arc::new(SystemMonitor::new()),
        }
    }
}

#[tauri::command]
pub async fn get_system_resources(
    state: State<'_, ParallelProcessorState>,
) -> Result<serde_json::Value, String> {
    state.system_monitor.refresh_system_info()
        .await
        .map_err(|e| format!("Failed to refresh system info: {}", e))?;

    let resources = state.system_monitor.get_current_resources()
        .await
        .map_err(|e| format!("Failed to get system resources: {}", e))?;

    serde_json::to_value(resources)
        .map_err(|e| format!("Failed to serialize resources: {}", e))
}
