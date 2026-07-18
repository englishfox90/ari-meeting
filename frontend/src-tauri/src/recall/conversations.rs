//! Tauri commands for Ask conversation persistence. The DTOs + `*_impl` fns now live in
//! `ari_engine::recall::conversations`; this module is the thin `#[tauri::command]`
//! surface, per the ari-engine carve's per-service migration recipe
//! (`docs/plans/ari-engine-carve.md`).

use std::sync::Arc;

use ari_engine::recall::conversations as engine_conversations;

pub use engine_conversations::{AskConversationDetailDto, AskConversationDto, AskMessageDto};

use crate::api::LocalRecallSource;
use crate::engine::Engine;

#[tauri::command]
pub async fn ask_conversation_list(
    engine: tauri::State<'_, Arc<Engine>>,
    meeting_id: Option<String>,
) -> Result<Vec<AskConversationDto>, String> {
    engine_conversations::ask_conversation_list_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn ask_conversation_get(
    engine: tauri::State<'_, Arc<Engine>>,
    conversation_id: String,
) -> Result<AskConversationDetailDto, String> {
    engine_conversations::ask_conversation_get_impl(&engine, conversation_id).await
}

#[tauri::command]
pub async fn ask_conversation_create(
    engine: tauri::State<'_, Arc<Engine>>,
    meeting_id: Option<String>,
    title: Option<String>,
) -> Result<String, String> {
    engine_conversations::ask_conversation_create_impl(&engine, meeting_id, title).await
}

#[tauri::command]
pub async fn ask_message_append(
    engine: tauri::State<'_, Arc<Engine>>,
    conversation_id: String,
    role: String,
    content: String,
    sources: Option<Vec<LocalRecallSource>>,
) -> Result<String, String> {
    engine_conversations::ask_message_append_impl(&engine, conversation_id, role, content, sources)
        .await
}

#[tauri::command]
pub async fn ask_conversation_delete(
    engine: tauri::State<'_, Arc<Engine>>,
    conversation_id: String,
) -> Result<(), String> {
    engine_conversations::ask_conversation_delete_impl(&engine, conversation_id).await
}
