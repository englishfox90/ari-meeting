// Person Profiles (F2) + Owner Context (F3) — additive module. Two-tier person model
// (authored identity + inferred facts w/ provenance & supersession), seeded from calendar
// attendee emails (F4), feeding a terse context block into the summary prompt (F3). See
// `.claude/context/product.md` F2/F3 and the frozen F2 implementation contract.

pub mod commands;
pub mod extraction;
pub mod import;
pub mod models;
pub mod reconciliation;
