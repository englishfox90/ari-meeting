//! `Engine` context + the Tauri-decoupling seams — Stage B of the ari-engine
//! carve (`docs/plans/ari-engine-carve.md`).
//!
//! `Engine`/`EventSink`/`Notifier`/`Paths`/`json_store` have all moved into
//! `ari_engine::engine` (pure, Tauri-free — see that module's docs). This host
//! module re-exports them at the same paths every existing `crate::engine::*`
//! reference already uses, plus keeps the Tauri-coupled pieces that can't move
//! (`TauriEventSink`, `TauriNotifier`, `paths::from_tauri`) — the host
//! constructs `Engine` with these injected and calls into it in-process.
pub mod context;
pub mod events;
pub mod json_store;
pub mod notifier;
pub mod paths;

pub use ari_engine::engine::{Engine, EventSink, Notifier, Paths};
pub use events::TauriEventSink;
pub use notifier::TauriNotifier;
