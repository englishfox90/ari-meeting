// Calendar feature (F4) — additive module. Pulls calendar events from macOS EventKit and
// links them to recordings (auto time-match + manual override). See
// `.claude/context/product.md` F4/F5 and the shared IPC contract for scope (F4 only, no
// F5 record-reminder notifications in this pass).

pub mod commands;
pub mod eventkit;
pub mod models;
pub mod sync;
