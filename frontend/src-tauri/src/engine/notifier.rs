//! Tauri-side `Notifier` implementation.
//!
//! The `Notifier` trait lives in `ari_engine::engine::notifier` (pure, only
//! depends on `async_trait`). `TauriNotifier` stays here because it wraps the
//! Runtime-generic, Tauri-plugin-typed `NotificationManager<tauri::Wry>` — see
//! that module's docs for the full host-capability rationale.
#![allow(dead_code)]

use async_trait::async_trait;
pub use ari_engine::engine::Notifier;

use crate::notifications::commands::NotificationManagerState;

/// Stage-A/B implementation: relays to the host-managed
/// `NotificationManager<tauri::Wry>`, so all consent/DND/settings gates and the
/// exact notification shapes are unchanged. The headless daemon (Stage D) will
/// inject a client-capability impl that forwards the *decision* to the host.
pub struct TauriNotifier {
    manager: NotificationManagerState<tauri::Wry>,
}

impl TauriNotifier {
    pub fn new(manager: NotificationManagerState<tauri::Wry>) -> Self {
        Self { manager }
    }
}

#[async_trait]
impl Notifier for TauriNotifier {
    async fn notify_recording_started(&self, meeting_name: Option<String>) {
        let guard = self.manager.read().await;
        if let Some(mgr) = guard.as_ref() {
            if let Err(e) = mgr.show_recording_started(meeting_name).await {
                log::warn!("Notifier: show_recording_started failed: {e}");
            }
        }
    }

    async fn notify_recording_stopped(&self) {
        let guard = self.manager.read().await;
        if let Some(mgr) = guard.as_ref() {
            if let Err(e) = mgr.show_recording_stopped().await {
                log::warn!("Notifier: show_recording_stopped failed: {e}");
            }
        }
    }

    async fn notify_meeting_reminder(&self, minutes: u64, title: Option<String>) {
        let guard = self.manager.read().await;
        if let Some(mgr) = guard.as_ref() {
            if let Err(e) = mgr.show_meeting_reminder(minutes, title).await {
                log::warn!("Notifier: show_meeting_reminder failed: {e}");
            }
        }
    }

    async fn meeting_reminder_leads(&self) -> Vec<i64> {
        let guard = self.manager.read().await;
        match guard.as_ref() {
            Some(mgr) => mgr
                .get_settings()
                .await
                .notification_preferences
                .meeting_reminder_minutes
                .iter()
                .map(|&m| m as i64)
                .collect(),
            None => vec![15, 5],
        }
    }
}
