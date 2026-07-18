/// Summary module - handles all meeting summary generation functionality
///
/// The pure logic (LLM clients, processor, service, templates, citations,
/// language detection, metadata I/O) now lives in `ari-engine::summary`; this
/// module re-exports what external callers still reach via `crate::summary::*`
/// module paths, plus the `#[tauri::command]` shims (`commands`,
/// `template_commands`, `template_selector`, `claude_cli`, `summary_engine`)
/// that stay host-side and call straight into the moved `_impl` fns, per the
/// ari-engine carve's per-service migration recipe
/// (`docs/plans/ari-engine-carve.md`).
///
/// This module contains:
/// - LLM client for communicating with various AI providers (OpenAI, Claude, Groq, Ollama, OpenRouter, CustomOpenAI)
/// - Processor for chunking transcripts and generating summaries
/// - Service layer for orchestrating summary generation
/// - Templates for structured meeting summary generation
/// - Tauri commands for frontend integration
// Module re-exports (not a glob — a glob would collide with this module's own
// `commands`/`template_commands`/`template_selector`/`claude_cli`, which stay
// host-side under the same names for the tauri::command shims).
pub use ari_engine::summary::llm_client;
pub use ari_engine::summary::llm_stream;
pub use ari_engine::summary::templates;
pub use ari_engine::summary::{
    processor::{
        chunk_text, clean_llm_markdown_output, extract_meeting_name_from_markdown,
        generate_meeting_summary, rough_token_count,
    },
    service::SummaryService,
    LLMProvider,
};
pub use ari_engine::models::CustomOpenAIConfig;

pub mod claude_cli;
pub mod commands;
pub mod summary_engine;
pub mod template_commands;
pub mod template_selector;

// Re-export Tauri commands (with their generated __cmd__ variants)
pub use commands::{
    __cmd__api_cancel_summary, __cmd__api_detect_transcript_summary_language,
    __cmd__api_get_meeting_detected_summary_language, __cmd__api_get_meeting_summary_language,
    __cmd__api_get_summary, __cmd__api_process_transcript,
    __cmd__api_save_meeting_detected_summary_language, __cmd__api_save_meeting_summary,
    __cmd__api_save_meeting_summary_language, __tauri_command_name_api_cancel_summary,
    __tauri_command_name_api_detect_transcript_summary_language,
    __tauri_command_name_api_get_meeting_detected_summary_language,
    __tauri_command_name_api_get_meeting_summary_language,
    __tauri_command_name_api_get_summary, __tauri_command_name_api_process_transcript,
    __tauri_command_name_api_save_meeting_detected_summary_language,
    __tauri_command_name_api_save_meeting_summary,
    __tauri_command_name_api_save_meeting_summary_language, api_cancel_summary,
    api_detect_transcript_summary_language, api_get_meeting_detected_summary_language,
    api_get_meeting_summary_language, api_get_summary, api_process_transcript,
    api_save_meeting_detected_summary_language, api_save_meeting_summary,
    api_save_meeting_summary_language,
};

// Re-export template commands
pub use template_commands::{
    __cmd__api_list_templates, __tauri_command_name_api_list_templates, api_list_templates,
};
