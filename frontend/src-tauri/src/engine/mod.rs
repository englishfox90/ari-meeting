//! `Engine` context + the Tauri-decoupling seams — Stage A of the ari-engine
//! carve (`docs/plans/ari-engine-carve.md`).
//!
//! This module is the fixed contract every command migrates onto: engine logic
//! takes `&Engine`, emits through `EventSink`, and resolves files through
//! `Paths`, so none of it names `AppHandle`/`tauri::State` directly. Once the
//! whole command surface conforms, the module lifts wholesale into the
//! standalone `ari-engine` crate (Stage B) with no logic change.
pub mod context;
pub mod events;
pub mod json_store;
pub mod notifier;
pub mod paths;

pub use context::Engine;
pub use events::{EventSink, TauriEventSink};
pub use notifier::{Notifier, TauriNotifier};
pub use paths::Paths;
