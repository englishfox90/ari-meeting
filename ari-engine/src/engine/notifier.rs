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
//! Stage A/B: the Tauri host's `TauriNotifier` wraps the host-managed
//! `NotificationManagerState`, so behavior is identical to today (every gate —
//! consent, DND, settings — is still enforced inside the manager). When
//! `notifications`/`system` migrates crate-side, engine logic keeps calling
//! `engine.notifier()` and only the injected impl changes.
#![allow(dead_code)]

use async_trait::async_trait;

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
