//! Apple on-device embedder (NLEmbedding via the apple-helper sidecar) — the DEFAULT recall
//! embedder. Zero download, works offline on macOS.
//!
//! This is a thin wrapper over the apple-helper `embedBatch` request. On any failure (sidecar
//! missing, NLEmbedding unavailable, etc.) it returns an honest `Err` so the indexer degrades to
//! lexical-only (No-Fake-State — never returns zero vectors).

/// Embed a batch of texts on-device. Returns one 512-d vector per input, in order.
pub async fn embed_batch(texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    crate::apple::helper::embed_batch(texts).await
}
