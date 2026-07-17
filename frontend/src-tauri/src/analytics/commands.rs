use std::sync::Arc;
use tauri::command;
use crate::analytics::AnalyticsClient;

// Global analytics client
static ANALYTICS_CLIENT: std::sync::Mutex<Option<Arc<AnalyticsClient>>> = std::sync::Mutex::new(None);

// NOTE: All other analytics command wrappers were removed as vestigial (Phase 1.5
// prune, 2026-07-17) — analytics/telemetry is inert (PostHog removed 2026-07-14).
// `track_meeting_ended` is kept because it has a genuine internal Rust caller
// (`audio/recording_commands.rs`), which calls it directly as a no-op tracking hook
// at the end of a recording's lifecycle.
#[command]
pub async fn track_meeting_ended(
    transcription_provider: String,
    transcription_model: String,
    summary_provider: String,
    summary_model: String,
    total_duration_seconds: Option<f64>,
    active_duration_seconds: f64,
    pause_duration_seconds: f64,
    microphone_device_type: String,
    system_audio_device_type: String,
    chunks_processed: u64,
    transcript_segments_count: u64,
    had_fatal_error: bool,
) -> Result<(), String> {
    let client = {
        let guard = ANALYTICS_CLIENT.lock().unwrap();
        guard.as_ref().cloned()
    };

    if let Some(client) = client {
        client.track_meeting_ended(
            &transcription_provider,
            &transcription_model,
            &summary_provider,
            &summary_model,
            total_duration_seconds,
            active_duration_seconds,
            pause_duration_seconds,
            &microphone_device_type,
            &system_audio_device_type,
            chunks_processed,
            transcript_segments_count,
            had_fatal_error,
        ).await
    } else {
        Err("Analytics client not initialized".to_string())
    }
}
