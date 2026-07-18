///
///  Store.swift — module doc for `AriKit.Store` (docs/plans/arikit-store.md).
///
///  `Store` holds the GRDB-backed persistence layer — the Swift mirror of today's Rust
///  `database::repositories` — and its `AppDatabase` single-owner entry point. One process owns
///  the database (plan principle 3); persistence goes through repositories only, never raw
///  SQLite handles scattered through feature code.
///
///  FOUNDATION SLICE landed (plan §10 steps 1–2): `AppDatabase`, the `v1_baseline` migrator, and
///  the `meeting`/`transcript`/`speaker`/`speakerSegment` tables + repositories.
///
///  SLICE 2 landed (plan §10 steps 3–5): `summary`, `meetingNote`, `person`, `profileFact` +
///  `profileFactSource` tables + repositories, including the read-time-computed provenance
///  (`sourceCount`/`sourceMeetingTitle`) and the repository-enforced `person.isOwner`
///  single-true-row invariant. Series, calendar, the snake→camel decode adapter, and the
///  legacy-library importer are later steps in the same plan — not built yet.
///
public enum Store {}
