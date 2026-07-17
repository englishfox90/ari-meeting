//! Notifier abstraction — the host-capability seam that lets engine logic
//! *decide when* to notify without holding the Runtime-generic, Tauri-plugin-typed
//! `NotificationManager<tauri::Wry>`.
//!
//! This is the third Tauri-decoupling seam of the ari-engine carve
//! (`docs/plans/ari-engine-carve.md`), and the one the plan flags as genuinely
//! tricky: `NotificationManager<R: Runtime>` cannot live in a headless engine,
//! so — exactly like the `[client-side]` permission split — the engine decides
//! *when* to notify while the host *shows* the notification.
//!
//! Stage A/B: `TauriNotifier` wraps the host-managed `NotificationManagerState`,
//! so behavior is identical to today (every gate — consent, DND, settings — is
//! still enforced inside the manager). When `notifications`/`system` migrates
//! crate-side, engine logic keeps calling `engine.notifier()` and only the
//! injected impl changes.
#![allow(dead_code)]

use async_trait::async_trait;

use crate::notifications::commands::NotificationManagerState;

/// Object-safe, Runtime-free notifier. Engine logic holds `Arc<dyn Notifier>`
/// and never names a `NotificationManager<R>`/`AppHandle`. Every method is
/// best-effort: a notification is never worth failing the caller, so failures
/// log and return, and a not-yet-initialized backend degrades to a sensible
/// default rather than erroring.
#[async_trait]
pub trait Notifier: Send + Sync {
    /// System notification that recording has started.
    async fn notify_recording_started(&self, meeting_name: Option<String>);

    /// System notification that recording has stopped.
    async fn notify_recording_stopped(&self);

    /// Best-effort meeting-reminder notification (gated by the backend's own
    /// consent/DND/settings). `minutes` is the lead time; `title` the meeting.
    async fn notify_meeting_reminder(&self, minutes: u64, title: Option<String>);

    /// The user's configured meeting-reminder lead times (minutes before start),
    /// read from notification settings. Falls back to `[15, 5]` when the backend
    /// is not yet initialized — matching today's `notch/scheduler` default.
    async fn meeting_reminder_leads(&self) -> Vec<i64>;
}

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
