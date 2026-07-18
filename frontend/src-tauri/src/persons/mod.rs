// Person Profiles (F2) + Owner Context (F3) — additive module. Two-tier person model
// (authored identity + inferred facts w/ provenance & supersession), seeded from calendar
// attendee emails (F4), feeding a terse context block into the summary prompt (F3). See
// `.claude/context/product.md` F2/F3 and the frozen F2 implementation contract.
//
// The pure logic (`extraction`, `import`, `models`, `reconciliation`) now lives in
// `ari-engine::persons`; this module re-exports what external host callers still reach via
// `crate::persons::*` module paths (calendar's attendee-import call sites), plus the
// `#[tauri::command]` shims (`commands`, registered in `lib.rs`) that call straight into the
// moved `_impl` fns, per the ari-engine carve's per-service migration recipe
// (`docs/plans/ari-engine-carve.md`).

pub mod commands;
pub use ari_engine::persons::{extraction, import, models, reconciliation};
