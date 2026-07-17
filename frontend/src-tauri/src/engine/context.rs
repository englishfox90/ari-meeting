//! The headless engine context — everything a command needs, with zero Tauri
//! types on its surface.
//!
//! This collapses the five separately-`.manage()`d Tauri states plus the
//! lazily-managed `AppState` into a single `Arc<Engine>`. During Stage A it is
//! held as one managed state inside the Tauri host; from Stage B the daemon
//! process owns it directly. Commands migrate from taking several
//! `tauri::State<'_, T>` params to taking `&Engine` (or `State<'_, Arc<Engine>>`
//! in the host shim), reaching sub-state through the accessors here.
//!
//! Notably absent: the `NotificationManager<tauri::Wry>` state. It is
//! Runtime-generic (Tauri-plugin-typed) and cannot live in a headless engine;
//! it becomes a *host capability* (the engine decides *when* to notify, the host
//! *shows* the notification), parallel to the `[client-side]` permission split.
//! `SystemAudioDetectorState` is intentionally dropped — it is dead (no
//! consumers; see `docs/plans/engine-extraction.md` deletion appendix).
#![allow(dead_code)]

use std::sync::Arc;

use tokio::sync::RwLock;

use crate::database::manager::DatabaseManager;
use crate::recall::embed_models::EmbedModelManagerState;
use crate::summary::summary_engine::ModelManagerState;
use crate::whisper_engine::parallel_commands::ParallelProcessorState;

use super::events::EventSink;
use super::paths::Paths;

pub struct Engine {
    /// Deferred: `None` until a first-launch flow initializes the DB, mirroring
    /// today's lazily-`.manage()`d `AppState` (which is why the host's shutdown
    /// path uses `try_state`). Reach it via [`Engine::db`].
    db: RwLock<Option<DatabaseManager>>,
    paths: Paths,
    events: Arc<dyn EventSink>,
    parallel: ParallelProcessorState,
    summary_models: ModelManagerState,
    embed_models: EmbedModelManagerState,
}

impl Engine {
    /// Construct the engine context. The three manager sub-states must be
    /// **shared clones** (same inner `Arc`s) of the instances the host still
    /// `.manage()`s during Stage A, so startup init that writes through the
    /// managed state is visible via [`Engine::summary_models`] et al. — the
    /// manager-state analog of [`Engine::set_db`] seeding. Once every consumer
    /// has migrated off `tauri::State` (Stage A exit), the host stops managing
    /// them separately and the engine owns them outright.
    pub fn new(
        paths: Paths,
        events: Arc<dyn EventSink>,
        parallel: ParallelProcessorState,
        summary_models: ModelManagerState,
        embed_models: EmbedModelManagerState,
    ) -> Self {
        Self {
            db: RwLock::new(None),
            paths,
            events,
            parallel,
            summary_models,
            embed_models,
        }
    }

    pub fn paths(&self) -> &Paths {
        &self.paths
    }

    /// Borrow the event sink to emit; `engine.events().emit("channel", payload)`.
    pub fn events(&self) -> &dyn EventSink {
        self.events.as_ref()
    }

    pub fn parallel(&self) -> &ParallelProcessorState {
        &self.parallel
    }

    pub fn summary_models(&self) -> &ModelManagerState {
        &self.summary_models
    }

    pub fn embed_models(&self) -> &EmbedModelManagerState {
        &self.embed_models
    }

    /// Install the DB manager once a first-launch/normal init resolves it.
    pub async fn set_db(&self, manager: DatabaseManager) {
        *self.db.write().await = Some(manager);
    }

    /// Clone out the DB manager (cheap — `DatabaseManager: Clone` over an
    /// `SqlitePool`). Errors if the DB has not been initialized yet, matching
    /// the host's `try_state` guard.
    pub async fn db(&self) -> Result<DatabaseManager, String> {
        self.db
            .read()
            .await
            .clone()
            .ok_or_else(|| "database not initialized".to_string())
    }

    /// True once the DB has been installed.
    pub async fn has_db(&self) -> bool {
        self.db.read().await.is_some()
    }
}
