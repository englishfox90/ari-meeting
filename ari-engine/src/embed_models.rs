//! Embedding-model catalog + a dedicated downloader/manager for the optional
//! nomic-embed-text GGUF. Fully additive and independent of the summary model catalog and
//! its `ModelManager` (they must never interfere), so switching or downloading an embedding
//! model can never touch a summary download or the summary sidecar.
//!
//! Downloaded models live under `app_data_dir/models/embeddings/`. The one catalog entry is
//! nomic-embed-text v1.5 (GGUF, mean-pooled, 768-d), run through the dedicated embed sidecar
//! instance in `embed_runtime.rs`.
//!
//! Moved from `frontend/src-tauri/src/recall/embed_models.rs` (Phase 1.5 carve, Stage B1) —
//! this is the Tauri-free half (catalog + `EmbedModelManager` + the `EmbedModelManagerState`
//! newtype). The `Engine`-touching half (`ensure_manager`, `*_impl` fns, `#[tauri::command]`
//! shims) stays in the host, which re-exports everything below.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::fs::{self, OpenOptions};
use tokio::io::{AsyncWriteExt, BufWriter};
use tokio::sync::{Mutex, RwLock};
use tokio::time::timeout;

// ============================================================================
// Catalog
// ============================================================================

/// A downloadable embedding model (GGUF).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EmbedModelDef {
    /// Stable id persisted by the frontend / used for lookups.
    pub name: String,
    /// Human label for the UI.
    pub display_name: String,
    /// GGUF filename on disk.
    pub gguf_file: String,
    /// HuggingFace `resolve/main/<file>` download URL.
    pub download_url: String,
    /// Approximate file size in MiB (for progress + validation variance).
    pub size_mb: u64,
    /// Context window used when creating the embedding context.
    pub n_ctx: u32,
    /// Short description for the UI.
    pub description: String,
}

/// The embedding-model catalog. One entry today: nomic-embed-text v1.5 (Q4_K_M).
pub fn get_available_embed_models() -> Vec<EmbedModelDef> {
    vec![EmbedModelDef {
        name: "nomic-embed-text-v1.5".to_string(),
        display_name: "Nomic Embed Text v1.5".to_string(),
        gguf_file: "nomic-embed-text-v1.5.Q4_K_M.gguf".to_string(),
        download_url:
            "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"
                .to_string(),
        size_mb: 84,
        n_ctx: 2048,
        description: "High-quality local text embedder (768-d, mean-pooled). ~84 MB download; runs through a dedicated llama-helper instance.".to_string(),
    }]
}

pub fn get_embed_model_by_name(name: &str) -> Option<EmbedModelDef> {
    get_available_embed_models()
        .into_iter()
        .find(|m| m.name == name)
}

/// The default (only) embedding model.
pub fn get_default_embed_model() -> EmbedModelDef {
    get_available_embed_models()
        .into_iter()
        .next()
        .expect("at least one embedding model must be defined")
}

/// Directory where downloaded embedding GGUFs live.
pub fn embeddings_directory(app_data_dir: &PathBuf) -> PathBuf {
    app_data_dir.join("models").join("embeddings")
}

/// Full on-disk path for a catalog model.
pub fn get_embed_model_path(app_data_dir: &PathBuf, model_name: &str) -> Result<PathBuf> {
    let model = get_embed_model_by_name(model_name)
        .ok_or_else(|| anyhow!("Unknown embedding model: {}", model_name))?;
    Ok(embeddings_directory(app_data_dir).join(&model.gguf_file))
}

// ============================================================================
// Status / info types (mirror the summary ModelManager shapes for a shared UI)
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EmbedModelStatus {
    NotDownloaded,
    Downloading { progress: u8 },
    Available,
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbedModelInfo {
    pub name: String,
    pub display_name: String,
    pub status: EmbedModelStatus,
    pub path: PathBuf,
    pub size_mb: u64,
    pub description: String,
    pub gguf_file: String,
}

#[derive(Debug, Clone, Copy)]
pub struct DownloadProgress {
    pub percent: u8,
    pub downloaded_mb: f64,
    pub total_mb: f64,
    pub speed_mbps: f64,
}

// ============================================================================
// Manager
// ============================================================================

pub struct EmbedModelManager {
    models_dir: PathBuf,
    statuses: Arc<RwLock<HashMap<String, EmbedModelStatus>>>,
    active_downloads: Arc<RwLock<HashSet<String>>>,
    cancel_flag: Arc<RwLock<Option<String>>>,
}

impl EmbedModelManager {
    pub fn new_with_dir(models_dir: PathBuf) -> Self {
        Self {
            models_dir,
            statuses: Arc::new(RwLock::new(HashMap::new())),
            active_downloads: Arc::new(RwLock::new(HashSet::new())),
            cancel_flag: Arc::new(RwLock::new(None)),
        }
    }

    pub async fn init(&self) -> Result<()> {
        if !self.models_dir.exists() {
            fs::create_dir_all(&self.models_dir).await?;
        }
        self.scan().await;
        Ok(())
    }

    /// Determine status of a single model from the filesystem, unless a download is in flight.
    async fn status_for(&self, def: &EmbedModelDef) -> EmbedModelStatus {
        {
            let active = self.active_downloads.read().await;
            if active.contains(&def.name) {
                // Preserve the in-memory Downloading status while a download runs.
                if let Some(s) = self.statuses.read().await.get(&def.name) {
                    return s.clone();
                }
            }
        }
        let path = self.models_dir.join(&def.gguf_file);
        if !path.exists() {
            return EmbedModelStatus::NotDownloaded;
        }
        match fs::metadata(&path).await {
            Ok(meta) => {
                let file_mb = meta.len() / (1024 * 1024);
                let min = (def.size_mb as f64 * 0.9) as u64;
                if file_mb >= min {
                    EmbedModelStatus::Available
                } else {
                    // Partial / too small — treat as not downloaded so it can resume.
                    EmbedModelStatus::NotDownloaded
                }
            }
            Err(e) => EmbedModelStatus::Error {
                message: format!("Failed to read metadata: {}", e),
            },
        }
    }

    /// Refresh cached statuses from disk.
    pub async fn scan(&self) {
        let mut map = HashMap::new();
        for def in get_available_embed_models() {
            map.insert(def.name.clone(), self.status_for(&def).await);
        }
        let mut statuses = self.statuses.write().await;
        *statuses = map;
    }

    pub async fn list_models(&self) -> Vec<EmbedModelInfo> {
        let mut out = Vec::new();
        for def in get_available_embed_models() {
            let status = {
                let statuses = self.statuses.read().await;
                statuses
                    .get(&def.name)
                    .cloned()
                    .unwrap_or(EmbedModelStatus::NotDownloaded)
            };
            out.push(EmbedModelInfo {
                name: def.name.clone(),
                display_name: def.display_name.clone(),
                status,
                path: self.models_dir.join(&def.gguf_file),
                size_mb: def.size_mb,
                description: def.description.clone(),
                gguf_file: def.gguf_file.clone(),
            });
        }
        out
    }

    pub async fn is_model_ready(&self, model_name: &str) -> bool {
        if let Some(def) = get_embed_model_by_name(model_name) {
            matches!(self.status_for(&def).await, EmbedModelStatus::Available)
        } else {
            false
        }
    }

    async fn set_status(&self, model_name: &str, status: EmbedModelStatus) {
        let mut statuses = self.statuses.write().await;
        statuses.insert(model_name.to_string(), status);
    }

    /// Download (or resume) a model, reporting detailed progress. Mirrors the summary
    /// downloader's range-resume + cancel behavior in a self-contained form.
    pub async fn download_detailed(
        &self,
        model_name: &str,
        on_progress: impl Fn(DownloadProgress) + Send,
    ) -> Result<()> {
        {
            let active = self.active_downloads.read().await;
            if active.contains(model_name) {
                return Err(anyhow!("Download already in progress"));
            }
        }
        let def = get_embed_model_by_name(model_name)
            .ok_or_else(|| anyhow!("Unknown embedding model: {}", model_name))?;

        {
            let mut active = self.active_downloads.write().await;
            active.insert(model_name.to_string());
        }
        {
            let mut cancel = self.cancel_flag.write().await;
            *cancel = None;
        }
        self.set_status(model_name, EmbedModelStatus::Downloading { progress: 0 })
            .await;

        // Ensure the target directory exists.
        if !self.models_dir.exists() {
            fs::create_dir_all(&self.models_dir).await?;
        }
        let file_path = self.models_dir.join(&def.gguf_file);

        // Already valid? Skip.
        if let Ok(meta) = fs::metadata(&file_path).await {
            let file_mb = meta.len() / (1024 * 1024);
            let min = (def.size_mb as f64 * 0.9) as u64;
            let max = (def.size_mb as f64 * 1.2) as u64;
            if file_mb >= min && file_mb <= max {
                self.set_status(model_name, EmbedModelStatus::Available).await;
                self.active_downloads.write().await.remove(model_name);
                let total = meta.len();
                on_progress(DownloadProgress {
                    percent: 100,
                    downloaded_mb: total as f64 / (1024.0 * 1024.0),
                    total_mb: total as f64 / (1024.0 * 1024.0),
                    speed_mbps: 0.0,
                });
                return Ok(());
            }
        }

        let existing_size: u64 = fs::metadata(&file_path)
            .await
            .map(|m| m.len())
            .unwrap_or(0);

        let client = Client::builder()
            .tcp_nodelay(true)
            .pool_max_idle_per_host(1)
            .timeout(Duration::from_secs(3600))
            .connect_timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| anyhow!("Failed to create HTTP client: {}", e))?;

        let mut request = client.get(&def.download_url);
        if existing_size > 0 {
            request = request.header("Range", format!("bytes={}-", existing_size));
        }
        let response = request
            .send()
            .await
            .map_err(|e| anyhow!("Failed to start download: {}", e))?;

        let (total_size, resuming) = if response.status() == reqwest::StatusCode::PARTIAL_CONTENT {
            let remaining = response.content_length().unwrap_or(0);
            (existing_size + remaining, true)
        } else if response.status().is_success() {
            (response.content_length().unwrap_or(0), false)
        } else {
            self.active_downloads.write().await.remove(model_name);
            self.set_status(model_name, EmbedModelStatus::NotDownloaded).await;
            return Err(anyhow!("Download failed with status: {}", response.status()));
        };

        let file = if resuming {
            OpenOptions::new()
                .write(true)
                .append(true)
                .open(&file_path)
                .await
                .map_err(|e| anyhow!("Failed to open file for append: {}", e))?
        } else {
            fs::File::create(&file_path)
                .await
                .map_err(|e| anyhow!("Failed to create file: {}", e))?
        };
        let mut writer = BufWriter::with_capacity(8 * 1024 * 1024, file);

        let mut downloaded: u64 = if resuming { existing_size } else { 0 };
        let mut last_percent = if total_size > 0 {
            ((downloaded as f64 / total_size as f64) * 100.0) as u8
        } else {
            0
        };
        let mut last_report = std::time::Instant::now();
        let mut bytes_since_report: u64 = 0;

        use futures_util::StreamExt;
        let mut stream = response.bytes_stream();

        loop {
            // Cancellation check.
            {
                let cancel = self.cancel_flag.read().await;
                if cancel.as_ref() == Some(&model_name.to_string()) {
                    let _ = writer.flush().await;
                    drop(writer);
                    self.active_downloads.write().await.remove(model_name);
                    self.set_status(model_name, EmbedModelStatus::NotDownloaded).await;
                    return Err(anyhow!("CANCELLED: Download cancelled by user"));
                }
            }

            let next = timeout(Duration::from_secs(30), stream.next()).await;
            let chunk = match next {
                Err(_) => {
                    let _ = writer.flush().await;
                    self.active_downloads.write().await.remove(model_name);
                    self.set_status(
                        model_name,
                        EmbedModelStatus::Error {
                            message: "Download timeout".to_string(),
                        },
                    )
                    .await;
                    return Err(anyhow!("Download timeout - No data received for 30 seconds"));
                }
                Ok(None) => break,
                Ok(Some(Ok(c))) => c,
                Ok(Some(Err(e))) => {
                    let _ = writer.flush().await;
                    self.active_downloads.write().await.remove(model_name);
                    self.set_status(
                        model_name,
                        EmbedModelStatus::Error {
                            message: format!("Download error: {}", e),
                        },
                    )
                    .await;
                    return Err(anyhow!("Download error: {}", e));
                }
            };
            let chunk_len = chunk.len() as u64;
            writer
                .write_all(&chunk)
                .await
                .map_err(|e| anyhow!("Error writing to file: {}", e))?;
            downloaded += chunk_len;
            bytes_since_report += chunk_len;

            let percent = if total_size > 0 {
                ((downloaded as f64 / total_size as f64) * 100.0).min(100.0) as u8
            } else {
                0
            };
            let elapsed = last_report.elapsed();
            let complete = total_size > 0 && downloaded >= total_size;
            if percent > last_percent || complete || elapsed.as_millis() >= 500 {
                let speed_mbps = if elapsed.as_secs_f64() > 0.0 {
                    (bytes_since_report as f64 / (1024.0 * 1024.0)) / elapsed.as_secs_f64()
                } else {
                    0.0
                };
                self.set_status(
                    model_name,
                    EmbedModelStatus::Downloading {
                        progress: if complete { 100 } else { percent },
                    },
                )
                .await;
                on_progress(DownloadProgress {
                    percent: if complete { 100 } else { percent },
                    downloaded_mb: downloaded as f64 / (1024.0 * 1024.0),
                    total_mb: total_size as f64 / (1024.0 * 1024.0),
                    speed_mbps,
                });
                last_percent = percent;
                last_report = std::time::Instant::now();
                bytes_since_report = 0;
            }
        }

        writer.flush().await?;
        drop(writer);

        // Validate GGUF magic.
        if let Err(e) = validate_gguf(&file_path).await {
            let _ = fs::remove_file(&file_path).await;
            self.active_downloads.write().await.remove(model_name);
            self.set_status(
                model_name,
                EmbedModelStatus::Error {
                    message: format!("Validation failed: {}", e),
                },
            )
            .await;
            return Err(anyhow!("File validation failed: {}", e));
        }

        self.set_status(model_name, EmbedModelStatus::Available).await;
        self.active_downloads.write().await.remove(model_name);
        on_progress(DownloadProgress {
            percent: 100,
            downloaded_mb: total_size as f64 / (1024.0 * 1024.0),
            total_mb: total_size as f64 / (1024.0 * 1024.0),
            speed_mbps: 0.0,
        });
        Ok(())
    }

    pub async fn cancel_download(&self, model_name: &str) {
        {
            let mut cancel = self.cancel_flag.write().await;
            *cancel = Some(model_name.to_string());
        }
        self.set_status(model_name, EmbedModelStatus::NotDownloaded).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    pub async fn delete_model(&self, model_name: &str) -> Result<()> {
        let def = get_embed_model_by_name(model_name)
            .ok_or_else(|| anyhow!("Unknown embedding model: {}", model_name))?;
        let path = self.models_dir.join(&def.gguf_file);
        if path.exists() {
            fs::remove_file(&path).await?;
        }
        self.set_status(model_name, EmbedModelStatus::NotDownloaded).await;
        Ok(())
    }
}

async fn validate_gguf(path: &PathBuf) -> Result<()> {
    use tokio::io::AsyncReadExt;
    let mut file = fs::File::open(path).await?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).await?;
    if &magic == b"GGUF" || &magic == b"ggjt" || &magic == b"ggla" || &magic == b"ggml" {
        Ok(())
    } else {
        Err(anyhow!("magic number {:?} doesn't match GGUF/GGML", magic))
    }
}

// ============================================================================
// Managed state
// ============================================================================

/// Global embed model manager, distinct from the summary `ModelManagerState`. The
/// `Engine`-touching `ensure_manager`/`*_impl`/`#[tauri::command]` layer that builds and
/// consumes this stays in the host (`frontend/src-tauri/src/recall/embed_models.rs`).
pub struct EmbedModelManagerState(pub Arc<Mutex<Option<Arc<EmbedModelManager>>>>);

impl EmbedModelManagerState {
    pub fn new() -> Self {
        Self(Arc::new(Mutex::new(None)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_has_nomic_entry_with_expected_metadata() {
        let def = get_embed_model_by_name("nomic-embed-text-v1.5")
            .expect("nomic model should be in the catalog");
        assert_eq!(def.display_name, "Nomic Embed Text v1.5");
        assert_eq!(def.gguf_file, "nomic-embed-text-v1.5.Q4_K_M.gguf");
        assert!(def
            .download_url
            .starts_with("https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/"));
        assert_eq!(def.n_ctx, 2048);
        assert!(def.size_mb > 0);
    }

    #[test]
    fn default_embed_model_is_the_nomic_entry() {
        assert_eq!(get_default_embed_model().name, "nomic-embed-text-v1.5");
    }

    #[test]
    fn unknown_model_lookup_returns_none() {
        assert!(get_embed_model_by_name("does-not-exist").is_none());
    }

    #[test]
    fn embed_model_path_lives_under_models_embeddings() {
        let base = PathBuf::from("/tmp/appdata");
        let path = get_embed_model_path(&base, "nomic-embed-text-v1.5").unwrap();
        assert!(path.ends_with("models/embeddings/nomic-embed-text-v1.5.Q4_K_M.gguf"));
    }
}
