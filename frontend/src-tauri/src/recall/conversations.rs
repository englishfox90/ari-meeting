//! Tauri commands for Ask conversation persistence with a 7-day retention window.
//! DTOs are camelCase to match the frontend; assistant `sources` are stored as JSON and
//! returned parsed (they remain app-authored — never trusted from the model).

use chrono::{Duration, Utc};
use serde::Serialize;
use uuid::Uuid;

use crate::api::LocalRecallSource;
use crate::database::models::{AskConversationRow, AskMessageRow};
use crate::database::repositories::ask_conversation::AskConversationRepository;
use crate::state::AppState;

const RETENTION_DAYS: i64 = 7;

fn retention_cutoff() -> String {
    (Utc::now() - Duration::days(RETENTION_DAYS)).to_rfc3339()
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AskConversationDto {
    pub id: String,
    pub meeting_id: Option<String>,
    pub title: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

impl From<AskConversationRow> for AskConversationDto {
    fn from(row: AskConversationRow) -> Self {
        Self {
            id: row.id,
            meeting_id: row.meeting_id,
            title: row.title,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AskMessageDto {
    pub id: String,
    pub conversation_id: String,
    pub role: String,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sources: Option<Vec<LocalRecallSource>>,
    pub created_at: String,
}

impl From<AskMessageRow> for AskMessageDto {
    fn from(row: AskMessageRow) -> Self {
        let sources = row
            .sources_json
            .as_deref()
            .and_then(|json| serde_json::from_str::<Vec<LocalRecallSource>>(json).ok());
        Self {
            id: row.id,
            conversation_id: row.conversation_id,
            role: row.role,
            content: row.content,
            sources,
            created_at: row.created_at,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AskConversationDetailDto {
    pub conversation: AskConversationDto,
    pub messages: Vec<AskMessageDto>,
}

#[tauri::command]
pub async fn ask_conversation_list(
    state: tauri::State<'_, AppState>,
    meeting_id: Option<String>,
) -> Result<Vec<AskConversationDto>, String> {
    let pool = state.db_manager.pool();
    // Enforce retention lazily on read.
    let _ = AskConversationRepository::prune_older_than(pool, &retention_cutoff()).await;
    let rows = AskConversationRepository::list(pool, meeting_id.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows.into_iter().map(AskConversationDto::from).collect())
}

#[tauri::command]
pub async fn ask_conversation_get(
    state: tauri::State<'_, AppState>,
    conversation_id: String,
) -> Result<AskConversationDetailDto, String> {
    let pool = state.db_manager.pool();
    let conversation = AskConversationRepository::get(pool, &conversation_id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Conversation not found.".to_string())?;
    let messages = AskConversationRepository::messages(pool, &conversation_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(AskConversationDetailDto {
        conversation: conversation.into(),
        messages: messages.into_iter().map(AskMessageDto::from).collect(),
    })
}

#[tauri::command]
pub async fn ask_conversation_create(
    state: tauri::State<'_, AppState>,
    meeting_id: Option<String>,
    title: Option<String>,
) -> Result<String, String> {
    let pool = state.db_manager.pool();
    let id = Uuid::new_v4().to_string();
    AskConversationRepository::create(
        pool,
        &id,
        meeting_id.as_deref(),
        title.as_deref(),
        &Utc::now().to_rfc3339(),
    )
    .await
    .map_err(|e| e.to_string())?;
    Ok(id)
}

#[tauri::command]
pub async fn ask_message_append(
    state: tauri::State<'_, AppState>,
    conversation_id: String,
    role: String,
    content: String,
    sources: Option<Vec<LocalRecallSource>>,
) -> Result<String, String> {
    if role != "user" && role != "assistant" {
        return Err("Unsupported message role.".to_string());
    }
    let pool = state.db_manager.pool();
    let message_id = Uuid::new_v4().to_string();
    let sources_json = sources
        .as_ref()
        .and_then(|s| serde_json::to_string(s).ok());
    AskConversationRepository::append_message(
        pool,
        &message_id,
        &conversation_id,
        &role,
        &content,
        sources_json.as_deref(),
        &Utc::now().to_rfc3339(),
    )
    .await
    .map_err(|e| e.to_string())?;
    // Opportunistic retention prune on write.
    let _ = AskConversationRepository::prune_older_than(pool, &retention_cutoff()).await;
    Ok(message_id)
}

#[tauri::command]
pub async fn ask_conversation_delete(
    state: tauri::State<'_, AppState>,
    conversation_id: String,
) -> Result<(), String> {
    let pool = state.db_manager.pool();
    AskConversationRepository::delete(pool, &conversation_id)
        .await
        .map_err(|e| e.to_string())
}
