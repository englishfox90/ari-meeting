pub mod ollama;
pub mod commands;

pub use ollama::*;
// `crate::ollama::metadata::ModelMetadataCache` is consumed by summary/service.rs;
// the real module now lives in ari-engine, re-exported here so the old path resolves.
pub use ari_engine::providers::ollama::metadata;
// Don't re-export commands to avoid conflicts - lib.rs will import directly
