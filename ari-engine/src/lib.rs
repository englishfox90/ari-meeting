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
//! B1 moves modules in one at a time; the host shrinks to command shims that
//! call into this crate, keeping every `crate::...` reference in the host
//! resolving unchanged via re-exports at the old paths.

// Performance optimization: conditional logging macros for hot paths, mirrored
// verbatim from the host's copy (frontend/src-tauri/src/lib.rs) so moved
// hot-path code (e.g. whisper_engine) keeps compiling without relying on
// macro_rules!'s textual-scope quirk across a crate boundary.
#[cfg(debug_assertions)]
macro_rules! perf_debug {
    ($($arg:tt)*) => {
        log::debug!($($arg)*)
    };
}

#[cfg(not(debug_assertions))]
macro_rules! perf_debug {
    ($($arg:tt)*) => {};
}

#[cfg(debug_assertions)]
macro_rules! perf_trace {
    ($($arg:tt)*) => {
        log::trace!($($arg)*)
    };
}

#[cfg(not(debug_assertions))]
macro_rules! perf_trace {
    ($($arg:tt)*) => {};
}

pub(crate) use perf_debug;
pub(crate) use perf_trace;

pub mod audio;
pub mod calendar;
pub mod config;
pub mod database;
pub mod embed_models;
pub mod engine;
pub mod language_preference;
pub mod meeting_series;
pub mod models;
pub mod providers;
pub mod summary_engine;
pub mod whisper_engine;
