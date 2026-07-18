//! # Diarization
//!
//! Speaker-diarization support for the meeting pipeline (F1 in the PRD).
//!
//! This module is intentionally split so that the **pure matching logic** lives
//! apart from any future engine/orchestration and Tauri command surface:
//!
//! - [`matching`] — a **pure, dependency-free** voiceprint matcher. No DB, no
//!   I/O, no async, no Tauri. It is trivially unit-testable and owns all of the
//!   cosine-similarity, running-mean enrollment, and threshold/margin tiering
//!   semantics ported from an older, production-proven `speakers.py`.
//! - `engine.rs` — stateful sidecar/model plumbing that pulls PCM/embeddings and
//!   calls into [`matching`].
//! - `commands.rs` / `voiceprint.rs` — the `*_impl` fns the host's thin
//!   `#[tauri::command]` shims call.
//!
//! The app layer owns **all** DB writes (via `database/repositories/`). This
//! module only computes; it never persists.
//!
//! Tauri-free per the ari-engine carve (`docs/plans/ari-engine-carve.md`): the
//! `#[tauri::command]` shims stay in the host
//! (`frontend/src-tauri/src/diarization/mod.rs`), which re-exports this module
//! so `crate::diarization::*` keeps resolving for existing callers (e.g. recall's
//! `labeling::resolve_meeting_speaker_labels`).

pub mod commands;
pub mod engine;
pub mod labeling;
pub mod matching;
pub mod postprocess;
pub mod tuning;
pub mod voiceprint;
