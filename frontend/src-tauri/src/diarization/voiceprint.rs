//! # Voiceprint identicon signatures (F1 visual mark) — host shims
//!
//! The pure math + read-only DB fetch (`*_impl` fns) now live in
//! `ari_engine::diarization::voiceprint`; this module is the thin
//! `#[tauri::command]` surface the frontend calls.

use std::sync::Arc;

use ari_engine::diarization::voiceprint as engine_voiceprint;
use ari_engine::engine::Engine;

pub use engine_voiceprint::{PersonVoiceprintSignature, VoiceprintSignature};

#[tauri::command]
pub async fn speaker_voiceprint_signatures(
    meeting_id: String,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<Vec<VoiceprintSignature>, String> {
    engine_voiceprint::speaker_voiceprint_signatures_impl(&engine, meeting_id).await
}

#[tauri::command]
pub async fn person_voiceprint_signature(
    person_id: String,
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<Option<PersonVoiceprintSignature>, String> {
    engine_voiceprint::person_voiceprint_signature_impl(&engine, person_id).await
}

#[tauri::command]
pub async fn person_voiceprint_signatures(
    engine: tauri::State<'_, Arc<Engine>>,
) -> Result<Vec<PersonVoiceprintSignature>, String> {
    engine_voiceprint::person_voiceprint_signatures_impl(&engine).await
}
