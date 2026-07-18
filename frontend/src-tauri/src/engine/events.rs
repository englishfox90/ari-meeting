//! Tauri-side `EventSink` implementation.
//!
//! The `EventSink` trait + its `emit` ergonomic helper live in
//! `ari_engine::engine::events` (pure, Tauri-free — see that module's docs).
//! `TauriEventSink` stays here because it wraps `tauri::AppHandle`: Stage A of
//! the ari-engine carve (`docs/plans/ari-engine-carve.md`) relays every event
//! straight to the Tauri host's `AppHandle::emit`, so the frontend's `listen()`
//! call sites are unaware the emit now flows through the sink.
#![allow(dead_code)]

pub use ari_engine::engine::EventSink;
use serde_json::Value;

/// Stage-A implementation: relays every event straight to the Tauri host's
/// `AppHandle::emit`, so the frontend's `listen()` call sites are unaware the
/// emit now flows through the sink.
pub struct TauriEventSink<R: tauri::Runtime> {
    app: tauri::AppHandle<R>,
}

impl<R: tauri::Runtime> TauriEventSink<R> {
    pub fn new(app: tauri::AppHandle<R>) -> Self {
        Self { app }
    }
}

impl<R: tauri::Runtime> EventSink for TauriEventSink<R> {
    fn emit_value(&self, channel: &str, payload: Value) {
        use tauri::Emitter;
        if let Err(e) = self.app.emit(channel, payload) {
            log::warn!("EventSink: emit '{channel}' failed: {e}");
        }
    }
}
