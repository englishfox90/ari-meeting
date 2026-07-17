// macOS audio permissions handling
use anyhow::Result;
use log::{info, warn, error};

#[cfg(target_os = "macos")]
use std::process::Command;

/// Check if the app has Audio Capture permission (required for Core Audio taps on macOS 14.4+)
///
/// Note: Core Audio taps require NSAudioCaptureUsageDescription in Info.plist.
/// When the app first attempts to create a Core Audio tap, macOS will automatically
/// show a permission dialog to the user. If permission is denied, the tap will return
/// silence (all zeros).
///
/// This function returns true because the actual permission prompt happens automatically
/// when AudioHardwareCreateProcessTap is called by the cidre library.
#[cfg(target_os = "macos")]
pub fn check_screen_recording_permission() -> bool {
    info!("ℹ️  Core Audio tap requires Audio Capture permission (macOS 14.4+)");
    info!("📍 Permission dialog will appear automatically when recording starts");
    info!("   If already granted: System Settings → Privacy & Security → Audio Capture");

    // Always return true - the actual permission dialog is triggered by Core Audio API
    true
}

#[cfg(not(target_os = "macos"))]
pub fn check_screen_recording_permission() -> bool {
    true // Not required on other platforms
}

/// Request Audio Capture permission from the user
/// This will open System Settings to the Privacy & Security page
#[cfg(target_os = "macos")]
pub fn request_screen_recording_permission() -> Result<()> {
    info!("🔐 Opening System Settings for Audio Capture permission...");

    // Open System Settings to Privacy & Security page
    // Note: There's no direct URL for Audio Capture, so we open the main Privacy page
    let result = Command::new("open")
        .arg("x-apple.systempreferences:com.apple.preference.security")
        .spawn();

    match result {
        Ok(_) => {
            info!("✅ Opened System Settings - navigate to Privacy & Security → Audio Capture");
            info!("👉 Please enable Audio Capture permission and restart the app");
            Ok(())
        }
        Err(e) => {
            error!("❌ Failed to open System Settings: {}", e);
            Err(anyhow::anyhow!("Failed to open System Settings: {}", e))
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn request_screen_recording_permission() -> Result<()> {
    Ok(()) // Not required on other platforms
}

/// Check and request Audio Capture permission if not granted
/// Returns true if permission is granted, false otherwise
pub fn ensure_screen_recording_permission() -> bool {
    if check_screen_recording_permission() {
        return true;
    }

    warn!("Audio Capture permission not granted - requesting...");

    if let Err(e) = request_screen_recording_permission() {
        error!("Failed to request Audio Capture permission: {}", e);
        return false;
    }

    false // Permission will be granted after restart
}

/// Tauri command to check Screen Recording permission
#[tauri::command]
pub async fn check_screen_recording_permission_command() -> bool {
    check_screen_recording_permission()
}

/// Tauri command to request Screen Recording permission
#[tauri::command]
pub async fn request_screen_recording_permission_command() -> Result<(), String> {
    request_screen_recording_permission()
        .map_err(|e| e.to_string())
}

/// Trigger system audio permission request and verify it was granted
/// Returns Ok(true) if permission granted (tap created successfully), Ok(false) if denied
#[cfg(target_os = "macos")]
pub fn trigger_system_audio_permission() -> Result<bool> {
    info!("🔐 Triggering Audio Capture permission request...");

    // Try to create a Core Audio capture - this triggers the permission dialog
    // if NSAudioCaptureUsageDescription is present in Info.plist
    // NOTE: We only create the tap, don't start streaming - similar to mic permission approach
    match crate::audio::capture::CoreAudioCapture::new() {
        Ok(_capture) => {
            info!("✅ Core Audio tap created successfully");
            // Sleep briefly to allow permission dialog to appear (if shown)
            // Similar to microphone permission handling in discovery.rs
            std::thread::sleep(std::time::Duration::from_millis(500));
            info!("✅ Audio Capture permission appears to be granted");
            // Note: On macOS, even with permission denied, tap creation may succeed
            // but audio will be silence. For onboarding, we just check tap creation.
            Ok(true)
        }
        Err(e) => {
            let error_msg = e.to_string().to_lowercase();
            if error_msg.contains("permission") || error_msg.contains("denied") {
                info!("🔐 Audio Capture permission denied");
                info!("👉 Please grant Audio Capture permission in System Settings");
                return Ok(false);
            }
            warn!("⚠️ Failed to create Core Audio tap: {}", e);
            // If tap creation fails for other reasons, still return false
            // as we can't verify permission status
            Ok(false)
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn trigger_system_audio_permission() -> Result<bool> {
    // System audio permissions not required on other platforms
    info!("System audio permissions not required on this platform");
    Ok(true)
}

/// Tauri command to trigger system audio permission request
/// Returns true if permission was granted (stream created), false if denied
#[tauri::command]
pub async fn trigger_system_audio_permission_command() -> Result<bool, String> {
    // Run in blocking task to avoid blocking the async runtime
    tokio::task::spawn_blocking(|| {
        trigger_system_audio_permission()
    })
    .await
    .map_err(|e| format!("Task join error: {}", e))?
    .map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// Non-blocking system-audio (Screen & System Audio Recording) preflight.
//
// `check_screen_recording_permission()` above is a legacy stub that always
// returns true, and the real permission gate is only hit *inside* the blocking
// `create_process_tap()` call during `start_recording` — so a missing grant
// looks like a frozen "Starting recording…". These helpers give the frontend a
// fast, non-blocking way to check (and prompt for) the grant BEFORE it enters
// the blocking capture path, so it can fail fast with guidance instead.
//
// A *global* Core Audio process tap (capturing all system output) is gated by
// the Screen Recording TCC bucket on macOS 15+, which is exactly what
// CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess report. Both
// are cheap, non-blocking, and do not present modal UI on the calling thread
// (the request shows the system prompt out-of-process and returns the current
// grant; a fresh grant only applies after an app restart).
#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

/// True if the app already holds the system-audio (screen-recording) grant.
#[cfg(target_os = "macos")]
pub fn preflight_system_audio_access() -> bool {
    unsafe { CGPreflightScreenCaptureAccess() }
}

/// Trigger the system prompt if the grant is undetermined. Returns the current
/// grant status; a newly-granted permission only takes effect after restart.
#[cfg(target_os = "macos")]
pub fn request_system_audio_access() -> bool {
    unsafe { CGRequestScreenCaptureAccess() }
}

#[cfg(not(target_os = "macos"))]
pub fn preflight_system_audio_access() -> bool {
    true
}

#[cfg(not(target_os = "macos"))]
pub fn request_system_audio_access() -> bool {
    true
}

/// Non-blocking check: does the app already have system-audio permission?
#[tauri::command]
pub async fn preflight_system_audio_permission_command() -> bool {
    let granted = preflight_system_audio_access();
    info!("🔎 System-audio permission preflight: granted={}", granted);
    granted
}

/// Prompt for system-audio permission (shows the system dialog if undetermined).
/// Returns the current grant; false means the user must grant it and relaunch.
#[tauri::command]
pub async fn prompt_system_audio_permission_command() -> bool {
    let granted = request_system_audio_access();
    info!("🔐 System-audio permission prompt result: granted={}", granted);
    granted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_check_permission() {
        let has_permission = check_screen_recording_permission();
        println!("Has Screen Recording permission: {}", has_permission);
    }
}