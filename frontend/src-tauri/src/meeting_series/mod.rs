// Meeting Series (F9) — additive feature module. Groups recurring meetings (calendar
// recurrence today; heuristic later) into a series with a rolling per-series ledger.
//
// The pure logic (`ledger`, `ledger_citations`, `models`, `detection`) now lives in
// `ari-engine::meeting_series`; this module re-exports what external host callers still
// reach via `crate::meeting_series::*` module paths, plus the `#[tauri::command]` shims
// (`commands`, registered in `lib.rs`) that call straight into the moved `_impl` fns, per the
// ari-engine carve's per-service migration recipe (`docs/plans/ari-engine-carve.md`).

pub mod commands;
pub use ari_engine::meeting_series::{detection, ledger, ledger_citations, models};
