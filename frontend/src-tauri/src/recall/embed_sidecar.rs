//! Nomic-embed-text GGUF embedder, run through a DEDICATED llama-helper sidecar instance
//! (separate from the summary sidecar, so embedding never thrashes the summary model).
//! Higher quality than the Apple default; requires a one-time model download.
//!
//! The actual sidecar lifecycle + protocol lives in `embed_runtime`; this module is the thin
//! entry point `recall::embedding` dispatches to for the `nomic-gguf` backend.

/// Embed a batch of texts via the nomic GGUF sidecar. Returns one 768-d (L2-normalized)
/// vector per input, in order. `Err` (model not downloaded, sidecar failure) degrades recall
/// to lexical-only.
pub async fn embed_batch(texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
    crate::recall::embed_runtime::embed_batch(texts).await
}
