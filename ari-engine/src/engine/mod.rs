//! `Engine` context + the Tauri-decoupling seams — Stage B of the ari-engine
//! carve (`docs/plans/ari-engine-carve.md`).
//!
//! This module is the fixed contract every command migrates onto: engine logic
//! takes `&Engine`, emits through `EventSink`, and resolves files through
//! `Paths`, so none of it names `AppHandle`/`tauri::State` directly. The host's
//! `#[tauri::command]` shims construct `Engine` (via the host's
//! `engine::paths::from_tauri` + `TauriEventSink`/`TauriNotifier`) and call into
//! it in-process; later (Stage D) the daemon owns it directly with no logic
//! change.
pub mod context;
pub mod events;
pub mod json_store;
pub mod notifier;
pub mod paths;

pub use context::Engine;
pub use events::EventSink;
pub use notifier::Notifier;
pub use paths::Paths;
