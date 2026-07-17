//! Vector helpers + embedder dispatch for recall. Embeddings are stored as packed
//! little-endian f32 bytes (opaque BLOB), matching the `speakers.centroid` convention — the
//! DB layer never interprets them; all math lives here.
//!
//! The embedder is pluggable and chosen by the persisted `recall_embedder` setting:
//! - `apple`      (default) — on-device Apple NLEmbedding via the apple-helper sidecar. No
//!                            download; works for everyone on macOS.
//! - `nomic-gguf`           — a downloaded nomic-embed-text GGUF via a dedicated llama-helper
//!                            sidecar instance (higher quality).
//! - `ollama`               — loopback Ollama `nomic-embed-text` (optional; never required).
//!
//! Each chunk records which backend embedded it (`model_tag`) so switching embedders forces a
//! clean re-embed and mismatched-dim vectors are skipped at search time.

use std::path::PathBuf;
use std::sync::OnceLock;

use sqlx::SqlitePool;

use crate::database::repositories::setting::SettingsRepository;

/// App-data dir, set once at startup so the GGUF embedder sidecar can locate its model file
/// without threading the path through the whole index pipeline (which runs in detached tasks).
static APP_DATA_DIR: OnceLock<PathBuf> = OnceLock::new();

pub fn set_app_data_dir(dir: PathBuf) {
    let _ = APP_DATA_DIR.set(dir);
}

pub fn app_data_dir() -> Option<PathBuf> {
    APP_DATA_DIR.get().cloned()
}

/// Which local embedder produces vectors for semantic search.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EmbedBackend {
    Apple,
    NomicGguf,
    Ollama,
}

impl EmbedBackend {
    /// Parse the persisted `recall_embedder` value; unknown / unset → Apple (the default).
    pub fn from_setting(value: Option<&str>) -> Self {
        match value.map(str::trim) {
            Some("nomic-gguf") | Some("nomic") => EmbedBackend::NomicGguf,
            Some("ollama") => EmbedBackend::Ollama,
            _ => EmbedBackend::Apple,
        }
    }

    /// Canonical setting id (what the frontend selector persists).
    pub fn id(self) -> &'static str {
        match self {
            EmbedBackend::Apple => "apple",
            EmbedBackend::NomicGguf => "nomic-gguf",
            EmbedBackend::Ollama => "ollama",
        }
    }

    /// Stable per-backend tag stored on each chunk so a change of embedder is detected and the
    /// meeting is re-embedded. Distinct backends produce incomparable vector spaces.
    pub fn model_tag(self) -> &'static str {
        match self {
            EmbedBackend::Apple => "apple-nl",
            EmbedBackend::NomicGguf => "nomic-embed-text-v1.5",
            EmbedBackend::Ollama => "ollama:nomic-embed-text",
        }
    }
}

pub async fn current_backend(pool: &SqlitePool) -> EmbedBackend {
    let value = SettingsRepository::get_recall_embedder(pool)
        .await
        .ok()
        .flatten();
    EmbedBackend::from_setting(value.as_deref())
}

pub async fn current_model_tag(pool: &SqlitePool) -> String {
    current_backend(pool).await.model_tag().to_string()
}

pub fn pack_f32(values: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(values.len() * 4);
    for value in values {
        bytes.extend_from_slice(&value.to_le_bytes());
    }
    bytes
}

pub fn unpack_f32(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

/// Cosine similarity in [-1, 1]. Returns 0.0 for empty or mismatched-length vectors — so a
/// vector produced by a different embedder (different dimension) simply never matches.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.is_empty() || a.len() != b.len() {
        return 0.0;
    }
    let mut dot = 0.0f32;
    let mut norm_a = 0.0f32;
    let mut norm_b = 0.0f32;
    for i in 0..a.len() {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }
    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }
    dot / (norm_a.sqrt() * norm_b.sqrt())
}

/// Embed a batch of documents with the configured backend. Best-effort: an `Err` means the
/// semantic arm is unavailable and the caller degrades to lexical-only. Returns one vector per
/// input, in order.
pub async fn embed_documents(pool: &SqlitePool, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }
    match current_backend(pool).await {
        EmbedBackend::Apple => crate::recall::embed_apple::embed_batch(texts).await,
        EmbedBackend::NomicGguf => crate::recall::embed_sidecar::embed_batch(texts).await,
        EmbedBackend::Ollama => embed_documents_ollama(pool, texts).await,
    }
}

/// Embed a single query string with the configured backend.
pub async fn embed_query(pool: &SqlitePool, text: &str) -> Result<Vec<f32>, String> {
    let batch = embed_documents(pool, std::slice::from_ref(&text.to_string())).await?;
    batch
        .into_iter()
        .next()
        .ok_or_else(|| "empty embedding result".to_string())
}

async fn embed_documents_ollama(
    pool: &SqlitePool,
    texts: &[String],
) -> Result<Vec<Vec<f32>>, String> {
    let endpoint = SettingsRepository::get_model_config(pool)
        .await
        .ok()
        .flatten()
        .and_then(|c| c.ollama_endpoint);
    let mut out = Vec::with_capacity(texts.len());
    for text in texts {
        out.push(crate::ollama::get_ollama_embedding(endpoint.as_deref(), "nomic-embed-text", text).await?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_parses_from_setting_with_apple_default() {
        assert_eq!(EmbedBackend::from_setting(None), EmbedBackend::Apple);
        assert_eq!(EmbedBackend::from_setting(Some("apple")), EmbedBackend::Apple);
        assert_eq!(EmbedBackend::from_setting(Some("nomic-gguf")), EmbedBackend::NomicGguf);
        assert_eq!(EmbedBackend::from_setting(Some("ollama")), EmbedBackend::Ollama);
        assert_eq!(EmbedBackend::from_setting(Some("weird")), EmbedBackend::Apple);
    }

    #[test]
    fn pack_roundtrip_preserves_values() {
        let original = vec![0.0f32, 1.5, -2.25, 3.125];
        let restored = unpack_f32(&pack_f32(&original));
        assert_eq!(original, restored);
    }

    #[test]
    fn cosine_identical_is_one_orthogonal_is_zero() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![1.0, 0.0, 0.0];
        let c = vec![0.0, 1.0, 0.0];
        assert!((cosine(&a, &b) - 1.0).abs() < 1e-6);
        assert!(cosine(&a, &c).abs() < 1e-6);
    }

    #[test]
    fn cosine_handles_mismatch_and_empty() {
        assert_eq!(cosine(&[1.0, 2.0], &[1.0]), 0.0);
        assert_eq!(cosine(&[], &[]), 0.0);
    }
}
