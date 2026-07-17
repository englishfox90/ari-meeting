//! `ari-engine` — the headless meeting-intelligence engine.
//!
//! Stage B of the ari-engine carve (`docs/plans/ari-engine-carve.md`). All the
//! Tauri-decoupled domain logic — audio, transcription engines, summary, recall,
//! calendar, persons, series, diarization, database, providers, plus the
//! `Engine`/`EventSink`/`Notifier`/`Paths` context — moves here module by module.
//! The Tauri host (`frontend/src-tauri`) becomes a thin client: its
//! `#[tauri::command]` shims call into this crate in-process (B2), and later
//! across a process boundary (Stage D) without the engine changing.
//!
//! **Empty scaffold today.** The crate exists and compiles so B1 has a target
//! to move modules into; no logic has been moved yet.

pub mod providers;
