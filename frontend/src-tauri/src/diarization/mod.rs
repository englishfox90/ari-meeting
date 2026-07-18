//! # Diarization
//!
//! The pure logic (matcher, sidecar/model plumbing, labeling, post-process,
//! tuning) now lives in `ari-engine::diarization`; this module re-exports it at
//! the old `crate::diarization::*` paths (used by `recall`/`persons` for
//! `labeling::resolve_meeting_speaker_labels` / `build_labeled_transcript_text`)
//! plus the thin `#[tauri::command]` shims that stay host-side.

pub use ari_engine::diarization::{engine, labeling, matching, postprocess, tuning};

pub mod commands;
pub mod voiceprint;
