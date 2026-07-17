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

use tokio::sync::{Mutex, RwLock};

use crate::database::manager::DatabaseManager;
use crate::recall::embed_models::EmbedModelManagerState;
use crate::summary::summary_engine::ModelManagerState;
use crate::whisper_engine::parallel_commands::ParallelProcessorState;

use super::events::EventSink;
use super::notifier::Notifier;
use super::paths::Paths;

pub struct Engine {
    /// Deferred: `None` until a first-launch flow initializes the DB, mirroring
    /// today's lazily-`.manage()`d `AppState` (which is why the host's shutdown
    /// path uses `try_state`). Reach it via [`Engine::db`].
    db: RwLock<Option<DatabaseManager>>,
    paths: Paths,
    events: Arc<dyn EventSink>,
    /// Deferred like [`Engine::db`]: `None` until the host builds the
    /// Runtime-generic notification backend and installs a [`Notifier`] impl.
    /// The engine only *decides when* to notify; the host capability *shows* it
    /// (see `engine/notifier.rs`). Absent → notifications silently no-op, which
    /// matches today's "manager not yet initialized" behavior.
    notifier: RwLock<Option<Arc<dyn Notifier>>>,
    parallel: ParallelProcessorState,
    summary_models: ModelManagerState,
    embed_models: EmbedModelManagerState,
}

impl Engine {
    /// Construct the engine context, owning its manager sub-states outright.
    /// (Earlier in Stage A these were shared clones of host-`.manage()`d
    /// instances; now the engine is the sole owner — the host no longer manages
    /// them separately, and startup writers reach them via
    /// `app.state::<Arc<Engine>>().summary_models()` etc.)
    pub fn new(paths: Paths, events: Arc<dyn EventSink>) -> Self {
        Self {
            db: RwLock::new(None),
            paths,
            events,
            notifier: RwLock::new(None),
            parallel: ParallelProcessorState::new(),
            summary_models: ModelManagerState(Arc::new(Mutex::new(None))),
            embed_models: EmbedModelManagerState::new(),
        }
    }

    pub fn paths(&self) -> &Paths {
        &self.paths
    }

    /// Borrow the event sink to emit; `engine.events().emit("channel", payload)`.
    /// Use this for emits that stay within the current async fn body.
    pub fn events(&self) -> &dyn EventSink {
        self.events.as_ref()
    }

    /// Clone out an **owned** event sink for use inside a `'static` context —
    /// a `move` closure (e.g. a download progress callback) or a spawned task —
    /// where a borrow from `&Engine` can't escape. `let sink = engine.event_sink();`
    /// then `sink.emit(...)` inside the closure.
    pub fn event_sink(&self) -> Arc<dyn EventSink> {
        self.events.clone()
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

    /// Install the host's [`Notifier`] capability once its Runtime-generic
    /// notification backend has finished startup (mirrors [`Engine::set_db`]).
    pub async fn set_notifier(&self, notifier: Arc<dyn Notifier>) {
        *self.notifier.write().await = Some(notifier);
    }

    /// Clone out the installed notifier, if any. Returns `None` until the host
    /// installs one — callers should treat that as "notifications not ready" and
    /// no-op, exactly as the underlying manager does before init.
    pub async fn notifier(&self) -> Option<Arc<dyn Notifier>> {
        self.notifier.read().await.clone()
    }
}
