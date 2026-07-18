//! `Engine` context + the Tauri-decoupling seams — Stage A/B of the ari-engine
//! carve (`docs/plans/ari-engine-carve.md`).
//!
//! This module is the fixed contract every command migrates onto: engine logic
//! takes `&Engine`, emits through `EventSink`, and resolves files through
//! `Paths`, so none of it names `AppHandle`/`tauri::State` directly.
//!
//! `Engine` itself (the struct that owns `db`/`paths`/`events`/`notifier`/the
//! manager sub-states) has NOT moved here yet — it holds a
//! `RwLock<Option<DatabaseManager>>`, and `DatabaseManager` (`database::manager`)
//! is still host-side (it takes `&tauri::AppHandle` to bootstrap the DB before
//! `Engine` exists). Moving `Engine` here first requires splitting
//! `DatabaseManager`'s pure pool/transaction/cleanup logic from its
//! `AppHandle`-taking constructors, mirroring the `Paths`/`Paths::from_tauri`
//! split below — that is a follow-up decision, not made in this pass.
pub mod events;
pub mod json_store;
pub mod notifier;
pub mod paths;

pub use events::EventSink;
pub use notifier::Notifier;
pub use paths::Paths;
