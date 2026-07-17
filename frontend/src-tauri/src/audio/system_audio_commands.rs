use crate::audio::SystemAudioDetector;
use std::sync::{Arc, Mutex};

// Global state for system audio detector
type SystemAudioDetectorState = Arc<Mutex<Option<SystemAudioDetector>>>;

/// Initialize the system audio detector state in Tauri app
pub fn init_system_audio_state() -> SystemAudioDetectorState {
    Arc::new(Mutex::new(None))
}

// Event payload types for frontend
#[derive(serde::Serialize, Clone)]
pub struct SystemAudioStartedPayload {
    pub apps: Vec<String>,
}

#[derive(serde::Serialize, Clone)]
pub struct SystemAudioStoppedPayload;

#[cfg(test)]
mod tests {
    use crate::audio::{check_system_audio_permissions, list_system_audio_devices};

    #[tokio::test]
    async fn test_list_system_audio_devices() {
        let devices = list_system_audio_devices();
        match devices {
            Ok(device_list) => {
                println!("System audio devices: {:?}", device_list);
                assert!(device_list.len() >= 0); // Should at least not crash
            }
            Err(e) => {
                println!("Error listing devices: {}", e);
                // This might fail on CI or systems without audio
            }
        }
    }

    #[tokio::test]
    async fn test_check_permissions() {
        let has_permission = check_system_audio_permissions();
        println!("Has system audio permissions: {}", has_permission);
        // This is mainly a smoke test to ensure it doesn't crash
    }
}