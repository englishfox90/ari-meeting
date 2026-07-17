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
//!
//! Later phases (not part of this module yet) will add:
//! - `engine.rs` — stateful orchestration that pulls PCM/embeddings and calls
//!   into [`matching`].
//! - `commands.rs` — the Tauri command surface.
//!
//! The app layer owns **all** DB writes (via `database/repositories/`). This
//! module only computes; it never persists.

pub mod commands;
pub mod engine;
pub mod labeling;
pub mod matching;
pub mod postprocess;
pub mod tuning;
pub mod voiceprint;
