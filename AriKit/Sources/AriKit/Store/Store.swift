///
///  Store.swift — module doc for `AriKit.Store` (docs/plans/arikit-store.md).
///
///  `Store` holds the GRDB-backed persistence layer — the Swift mirror of today's Rust
///  `database::repositories` — and its `AppDatabase` single-owner entry point. One process owns
///  the database (plan principle 3); persistence goes through repositories only, never raw
///  SQLite handles scattered through feature code.
///
///  FOUNDATION SLICE landed (plan §10 steps 1–2): `AppDatabase`, the `v1_baseline` migrator, and
///  the `meeting`/`transcript`/`speaker`/`speakerSegment` tables + repositories. Persons,
///  profile facts, series, calendar, summary, and meeting-notes tables/repositories, tombstones
///  across all tables, the snake→camel decode adapter, and the legacy-library importer are later
///  steps in the same plan — not built yet.
///
public enum Store {}
