//! Ari Notch feature — shared IPC protocol between the Rust core and the
//! notch/capsule sidecar. WS-A owns only the wire protocol; the bridge,
//! scheduler, Swift layer, and Tauri commands land in later workstreams.

pub mod protocol;

// WS-B: Rust bridge that owns the `ari-notch` sidecar and translates between
// Tauri recording events and the notch IPC protocol.
pub mod bridge;
pub mod resolver;

// WS-D: background reminder scheduler that fires upcoming-meeting alerts to the
// notch (and the system notification path), completing F5.
pub mod scheduler;
