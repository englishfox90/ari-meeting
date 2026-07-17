///
///  Store.swift — SCAFFOLD, no engine code yet, gated by Phase 3.
///
///  Per plans/swift-migration-plan.md, this module will hold the Point-Free SQLiteData
///  store (GRDB semantics; local source of truth + CloudKit sync results layer) and its
///  repository layer — the Swift mirror of today's Rust `database::repositories`. One
///  process owns the database (plan principle 3); persistence goes through repositories
///  only, never raw SQLite handles scattered through feature code.
///
public enum Store {}
