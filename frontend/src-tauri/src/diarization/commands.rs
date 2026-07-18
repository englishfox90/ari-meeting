//! # Diarization orchestration + Tauri command surface (F1) — host shims
//!
//! The pure orchestration (`*_impl` fns tying together the matcher, sidecar
//! plumbing, and DB writes via `database/repositories/`) now lives in
//! `ari_engine::diarization::commands`; this module is the thin
//! `#[tauri::command]` surface the frontend calls, per the ari-engine carve's
//! per-service migration recipe (`docs/plans/ari-engine-carve.md`).

use std::sync::Arc;

use ari_engine::diarization::commands as engine_commands;
use ari_engine::engine::Engine;

pub use engine_commands::{
    DiarizeMeetingSummary, MeetingSpeakerRow, ResetOwnerVoiceprintResult, SpeakerAssignResult,
    SpeakerMatchSuggestion, TranscriptSpeakerLabel,
};

#[tauri::command]
pub async fn meeting_speaker_labels(
    meeting_id: String,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<Vec<TranscriptSpeakerLabel>, String> {
    engine_commands::meeting_speaker_labels_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn diarize_meeting(
    meeting_id: String,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<DiarizeMeetingSummary, String> {
    engine_commands::diarize_meeting_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn speaker_reset_owner_voiceprint(
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<ResetOwnerVoiceprintResult, String> {
    engine_commands::speaker_reset_owner_voiceprint_impl(&engine).await
}

#[tauri::command]
pub async fn speaker_list_for_meeting(
    meeting_id: String,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<Vec<MeetingSpeakerRow>, String> {
    engine_commands::speaker_list_for_meeting_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn speaker_reassign_transcript_line(
    meeting_id: String,
    transcript_id: String,
    speaker_id: Option<String>,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<bool, String> {
    engine_commands::speaker_reassign_transcript_line_impl(&engine, meeting_id, transcript_id, speaker_id)
        .await
}

#[tauri::command]
pub async fn speaker_assign_to_person(
    speaker_id: String,
    person_id: String,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<SpeakerAssignResult, String> {
    engine_commands::speaker_assign_to_person_impl(&engine, speaker_id, person_id).await
}

#[tauri::command]
pub async fn speaker_match_suggestions(
    speaker_id: String,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<Vec<SpeakerMatchSuggestion>, String> {
    engine_commands::speaker_match_suggestions_impl(&engine, speaker_id).await
}
