//! `Engine` context + the Tauri-decoupling seams — Stage A/B of the ari-engine
//! carve (`docs/plans/ari-engine-carve.md`).
//!
//! `EventSink`/`Notifier`/`Paths`/`json_store` have moved into
//! `ari_engine::engine` (pure, Tauri-free — see that module's docs). This host
//! module re-exports them at the same paths every existing `crate::engine::*`
//! reference already uses, plus keeps the Tauri-coupled pieces that can't move
//! (`TauriEventSink`, `TauriNotifier`, `paths::from_tauri`) and `Engine` itself
//! (still host-side: it holds a `DatabaseManager`, which is still host-side —
//! see `context.rs` and `ari_engine::engine`'s module doc for why).
pub mod context;
pub mod events;
pub mod json_store;
pub mod notifier;
pub mod paths;

pub use ari_engine::engine::{EventSink, Notifier, Paths};
pub use context::Engine;
pub use events::TauriEventSink;
pub use notifier::TauriNotifier;
