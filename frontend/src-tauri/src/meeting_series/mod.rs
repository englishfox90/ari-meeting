// Meeting Series (F9) — additive feature module. Groups recurring meetings (calendar
// recurrence today; heuristic later) into a series with a rolling per-series ledger.
//
// - `models`    — camelCase wire DTOs for the Tauri command surface.
// - `commands`  — the `#[tauri::command]`s (registered in `lib.rs`).
// - `detection` — series detection run from calendar sync after auto-match.
// - `ledger`    — series ledger reduce (Phase B2, implemented by another agent).
// - `ledger_citations` — meeting-attributed `@mref(m<N>@<TS>)` citation rewrite/validation.

pub mod commands;
pub use ari_engine::meeting_series::detection;
pub mod ledger;
pub mod ledger_citations;
pub mod models;
