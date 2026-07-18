//! Resolved filesystem locations the engine needs, computed once at startup.
//!
//! Replaces the ~25 scattered `app.path().app_data_dir()` calls with one
//! resolved struct. Stage A resolves it from the Tauri host (the host's
//! `paths::from_tauri` free function); the headless daemon (Stage D) will
//! resolve the same paths natively. The subdirectory helpers reproduce today's
//! conventional layout exactly, so the app-data location (models, DB,
//! embeddings) is unchanged across the carve.
#![allow(dead_code)]

use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Paths {
    /// OS app-data dir (`~/Library/Application Support/<bundle-id>`) — the
    /// workhorse: DB file, downloaded models, embeddings all live under here.
    pub app_data: PathBuf,
    /// Rolling log dir (`~/Library/Logs/<bundle-id>`).
    pub app_log: PathBuf,
    /// App-config dir — F3 organization/global config.
    pub app_config: PathBuf,
    /// Bundled-resource dir — only used to locate the shipped `templates/`.
    pub resource: PathBuf,
}

impl Paths {
    /// `<app_data>/models` — whisper + parakeet model root.
    pub fn models(&self) -> PathBuf {
        self.app_data.join("models")
    }

    /// `<app_data>/models/summary` — llama-helper GGUF summary model.
    pub fn summary_models(&self) -> PathBuf {
        self.models().join("summary")
    }

    /// `<app_data>/models/embeddings` — recall embedder models.
    pub fn embedding_models(&self) -> PathBuf {
        self.models().join("embeddings")
    }

    /// `<resource>/templates` — bundled summary templates.
    pub fn bundled_templates(&self) -> PathBuf {
        self.resource.join("templates")
    }
}
