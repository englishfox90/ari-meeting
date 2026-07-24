---
name: grdb
description: GRDB.swift foundation patterns for the AriKit.Store port — DatabaseQueue/Pool + WAL, DatabaseMigrator, FetchableRecord/PersistableRecord records, the repository pattern (the Swift mirror of the Rust repositories-only rule), ValueObservation, and the single-DB-owner invariant. The chosen store is Point-Free SQLiteData (decided 2026-07-16), which rests on these GRDB semantics. Use when porting SQLite persistence to Swift or adding any store-backed data.
---

# GRDB for AriKit.Store

The Store port (Phase 3.1) replaces `sqlx` + `frontend/src-tauri/src/database/repositories/` with the Swift store. GRDB maps to the existing repository pattern almost 1:1. This skill is the house style for that layer.

> **Store DECIDED (2026-07-16): Point-Free SQLiteData.** Chosen over SwiftData / `NSPersistentCloudKitContainer` because recall (FTS5 / sqlite-vec / BM25⊕vector RRF) needs raw SQL that SwiftData hides — SQLiteData is real SQLite + first-class CloudKit sync with no hand-rolled conflict logic. Spike **S4 confirms it's load-bearing** (validates sync + recall-SQL coexistence); it is no longer a *choice* to make. **SQLiteData is built on GRDB semantics**, so everything below — the single-owner rule, migrations, records, the repository pattern — is exactly the foundation SQLiteData rests on. Use SQLiteData's `@Table`/sync layer on top; keep this repository shape underneath.

## Non-negotiable invariants (carried from the Rust engine)

- **One process owns the database.** Exactly one `DatabaseQueue`/`DatabasePool` per file, in the DB-owning process. Never open the SQLite file from a second ORM or process (plan principle 3). No `sqlx` + GRDB on the same file — `sqlx`'s `_sqlx_migrations` table is invisible to GRDB, and dual-WAL writers corrupt.
- **All access goes through a repository.** Feature code never holds a raw `Database`/`Row`. This is the Swift mirror of "DB access through `database/repositories/` only."
- **WAL mode**, matching today's setup.

## Setup — the single owner

```swift
import GRDB

/// Owns the one connection to the meeting database. Inject repositories off this.
public final class AppDatabase: Sendable {
    private let dbWriter: any DatabaseWriter   // DatabasePool in prod, DatabaseQueue in tests

    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    /// Production: WAL pool at the app-data path (the same dir the Tauri app uses today,
    /// ~/Library/Application Support/com.meetily.ai/, until the Phase-2 import migrator moves it).
    public static func makeShared(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)  // WAL by default
        return try AppDatabase(pool)
    }

    /// Tests: in-memory queue.
    public static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    // Repositories read/write only through these — never expose dbWriter.
    func read<T>(_ value: @Sendable (Database) throws -> T) async throws -> T {
        try await dbWriter.read(value)
    }
    func write<T>(_ updates: @Sendable (Database) throws -> T) async throws -> T {
        try await dbWriter.write(updates)
    }
}
```

Use `DatabasePool` (concurrent reads, one writer) in production; `DatabaseQueue` (serial) for tests. `any DatabaseWriter` lets the same code target both.

## Migrations — `DatabaseMigrator`

Ordered, named, run-once. **Freeze the sqlx migrations at cutover** and re-express the resulting schema as the GRDB baseline; do not try to co-read `_sqlx_migrations`.

```swift
// eraseOnSchemaChange defaults to false — see the ⚠️ note below. Only the app's
// ARI_RESET_STORE=1 opt-in ever passes true (a deliberate dev clean-slate).
static func migrator(eraseOnSchemaChange: Bool = false) -> DatabaseMigrator {
    var m = DatabaseMigrator()
    m.eraseDatabaseOnSchemaChange = eraseOnSchemaChange

    m.registerMigration("v1_baseline") { db in
        try db.create(table: "meeting") { t in
            t.primaryKey("id", .text)
            t.column("title", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(table: "transcript") { t in
            t.primaryKey("id", .text)
            t.belongsTo("meeting", onDelete: .cascade).notNull()
            t.column("text", .text).notNull()
            t.column("speakerId", .text).indexed()        // F1 speaker identity
        }
    }
    // Each later schema change is a NEW registered migration — never edit a shipped one.
    return m
}
```

⚠️ **`v1_baseline` is FROZEN (2026-07-22 incident).** It used to be extended in place while "unshipped," and `eraseDatabaseOnSchemaChange = true` was on in DEBUG. Together they silently wiped a real 22-meeting DB when a DEBUG build detected the changed baseline. The baseline is now shipped: **every future schema change is a new `v2+` `registerMigration` (`ALTER TABLE`/new table/new index), never an edit to `v1_baseline`.** Full incident + design: `docs/plans/robust-migration-and-backup.md`.

## Records — Codable + GRDB protocols

```swift
struct Meeting: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    var id: String
    var title: String
    var createdAt: Date

    // Type-safe columns for queries and associations.
    enum Columns { static let createdAt = Column(CodingKeys.createdAt) }
}
```

`FetchableRecord` = readable; `PersistableRecord` = insert/update/delete; `Codable` gives column mapping for free. Prefer `Identifiable` for SwiftUI. Keep records `Sendable` (value types) so they cross actor boundaries cleanly under Swift 6.

## Repository pattern

One repository per aggregate; it takes `AppDatabase` and exposes domain methods, never raw SQL to callers.

```swift
struct MeetingRepository: Sendable {
    let db: AppDatabase

    func all() async throws -> [Meeting] {
        try await db.read { try Meeting.order(Meeting.Columns.createdAt.desc).fetchAll($0) }
    }
    func save(_ meeting: Meeting) async throws {
        try await db.write { try meeting.save($0) }
    }
    func transcripts(of meetingID: String) async throws -> [Transcript] {
        try await db.read {
            try Transcript.filter(Column("meetingId") == meetingID).fetchAll($0)
        }
    }
}
```

## Live UI updates — `ValueObservation`

For SwiftUI lists that must reflect DB changes, use `ValueObservation` rather than polling (this replaces the Tauri 1s `is_recording` poll pattern for data views).

```swift
let observation = ValueObservation.tracking { db in
    try Meeting.order(Meeting.Columns.createdAt.desc).fetchAll(db)
}
// bridge to an @Observable view model via observation.values(in:) async sequence
```

## Testing

- In-memory `DatabaseQueue`, run the real migrator, assert against fetched records.
- Port the recall safety-shell tests here first when `AriKit.Recall` lands (loopback-only, bounded context, never-invents-citations) — dual-run against the Rust incumbent (plan principle 2).

## Gotchas

- `DatabasePool` needs WAL (default for pools) — don't force `journal_mode=DELETE`.
- Set `PRAGMA foreign_keys = ON` in `prepareDatabase` (off by default in SQLite).
- `eraseDatabaseOnSchemaChange` **DROPS THE ENTIRE DATABASE** on any schema mismatch — it silently wiped a real 22-meeting DB on 2026-07-22. It is now **off by default** (`SchemaMigrator.migrator(eraseOnSchemaChange:)`); only the app's `ARI_RESET_STORE=1` opt-in ever turns it on. Never default it true, even in DEBUG. A real mismatch must surface as an honest `.failed` launch status, never a wipe.
- Dates: GRDB stores `Date` as ISO-8601 text by default; match whatever format the Phase-2 import migrator reads from the legacy `sqlx` DB, or convert explicitly.
- Don't add a second `DatabaseQueue` "just for this one read" — that's a second owner. Route it through `AppDatabase`.
