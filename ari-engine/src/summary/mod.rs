//! Summary module — handles all meeting summary generation logic.
//!
//! Moved from `frontend/src-tauri/src/summary/` (Phase 1.5 carve, Stage B1).
//! Tauri-free: the `#[tauri::command]` shims stay host-side
//! (`frontend/src-tauri/src/summary/`), calling straight into the `_impl` fns
//! here per the ari-engine carve's per-service migration recipe
//! (`docs/plans/ari-engine-carve.md`).
//!
//! This module contains:
//! - LLM client for communicating with various AI providers (OpenAI, Claude, Groq, Ollama, OpenRouter, CustomOpenAI)
//! - Processor for chunking transcripts and generating summaries
//! - Service layer for orchestrating summary generation
//! - Templates for structured meeting summary generation

pub mod citations;
pub mod claude_cli;
pub mod commands;
pub mod language_detection;
pub mod llm_client;
pub mod llm_stream;
pub mod metadata;
pub mod processor;
pub mod service;
pub mod template_commands;
pub mod template_selector;
pub mod templates;

// Re-export commonly used items
pub use llm_client::LLMProvider;
pub use processor::{
    chunk_text, clean_llm_markdown_output, extract_meeting_name_from_markdown,
    generate_meeting_summary, rough_token_count,
};
pub use service::SummaryService;
