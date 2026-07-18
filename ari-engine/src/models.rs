//! Pure serde domain-model structs moved verbatim out of the Tauri host crate
//! (Stage B1 of the ari-engine carve, `docs/plans/ari-engine-carve.md`). These
//! are IPC payload shapes with zero Tauri dependencies. The host crate
//! re-exports each at its original `crate::...` path so existing references
//! keep compiling unchanged.

use serde::{Deserialize, Serialize};

// --- moved from frontend/src-tauri/src/api/api.rs ---

#[derive(Debug, Serialize, Deserialize)]
pub struct TranscriptSearchResult {
    pub id: String,
    pub title: String,
    #[serde(rename = "matchContext")]
    pub match_context: String,
    pub timestamp: String,
    #[serde(rename = "meetingDate")]
    pub meeting_date: Option<String>,
    pub summary: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MeetingDetails {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
    pub transcripts: Vec<MeetingTranscript>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MeetingTranscript {
    pub id: String,
    pub text: String,
    pub timestamp: String,
    // Recording-relative timestamps for audio-transcript synchronization
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_start_time: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_end_time: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    // F1 diarization: the resolved speaker for this line (NULL until diarized/matched).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TranscriptSegment {
    pub id: String,
    pub text: String,
    pub timestamp: String,
    // NEW: Recording-relative timestamps for playback synchronization
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_start_time: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_end_time: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
}

// --- moved from frontend/src-tauri/src/persons/models.rs ---

/// Authored-identity input. If `id` is present, updates that row. Else, if `email` is
/// present and a row already exists for it, updates that row. Otherwise inserts a new
/// person. Never touches `is_owner` (see `PersonRepository::upsert_authored`).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewPerson {
    pub id: Option<String>,
    pub email: Option<String>,
    pub display_name: String,
    pub role: Option<String>,
    pub organization: Option<String>,
    pub domain: Option<String>,
    pub notes: Option<String>,
}

// --- moved from frontend/src-tauri/src/summary/mod.rs ---

/// Custom OpenAI-compatible endpoint configuration
/// Stored as JSON in the database and used for connecting to any OpenAI-compatible API server
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomOpenAIConfig {
    /// Base URL of the OpenAI-compatible API endpoint (e.g., "http://localhost:8000/v1")
    pub endpoint: String,
    /// API key for authentication (optional if server doesn't require it)
    #[serde(rename = "apiKey")]
    pub api_key: Option<String>,
    /// Model identifier to use (e.g., "gpt-4", "llama-3-70b", "mistral-7b")
    pub model: String,
    /// Maximum tokens for completion (optional)
    #[serde(rename = "maxTokens")]
    pub max_tokens: Option<i32>,
    /// Temperature parameter (0.0-2.0, optional)
    pub temperature: Option<f32>,
    /// Top-P sampling parameter (0.0-1.0, optional)
    #[serde(rename = "topP")]
    pub top_p: Option<f32>,
}
