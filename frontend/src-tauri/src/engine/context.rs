//! `Engine` moved to `ari_engine::engine::context` (Phase 1.5 carve, Stage B1)
//! now that its last host-only field type, `DatabaseManager`, has a pure
//! definition in `ari_engine::database::manager`.
pub use ari_engine::engine::Engine;
