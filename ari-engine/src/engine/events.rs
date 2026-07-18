//! Event sink abstraction — the seam that lets engine logic emit events without
//! naming an `AppHandle`.
//!
//! Stage A of the ari-engine carve (see `docs/plans/ari-engine-carve.md`):
//! the Tauri host's `TauriEventSink` wraps `AppHandle`'s `emit`, so behavior is
//! identical to today. Stage D swaps in a stdout-NDJSON sink inside the
//! headless daemon — engine code that emits through this trait needs no change
//! at that point.
#![allow(dead_code)]

use serde::Serialize;
use serde_json::Value;

/// Object-safe event emitter. Engine logic holds `Arc<dyn EventSink>` and never
/// names an `AppHandle`. The single method keeps the trait object-safe; use the
/// `emit` helper below for the ergonomic `Serialize` call shape that mirrors
/// today's `app.emit(channel, payload)`.
pub trait EventSink: Send + Sync {
    /// Emit an already-serialized payload on `channel`. Must not block the
    /// caller (event emission is fire-and-forget from a hot path).
    fn emit_value(&self, channel: &str, payload: Value);
}

// Lifetime-generic so the helper is available on a `&dyn EventSink` of ANY
// lifetime — not just `&(dyn EventSink + 'static)`. Without the `+ 'a`, a bare
// `&dyn EventSink` threaded through a function parameter (its object bound
// elided to the borrow's own lifetime) can't reach `emit`, forcing callers to
// pass an owned `Arc<dyn EventSink>` unnecessarily.
impl<'a> dyn EventSink + 'a {
    /// Ergonomic mirror of `app.emit(channel, payload)` for any `Serialize`
    /// payload. A payload that fails to serialize degrades to `null` rather
    /// than panicking — an event is never worth taking the process down.
    pub fn emit<T: Serialize>(&self, channel: &str, payload: T) {
        let value = serde_json::to_value(payload).unwrap_or(Value::Null);
        self.emit_value(channel, value);
    }
}
