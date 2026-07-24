//
//  AppDatabase.swift — the single owner of the AriKit SQLite file (plan principle 3;
//  docs/plans/arikit-store.md §2.2/§3).
//
//  `AppDatabase` is an `actor` so construction (which runs the migrator) is isolated, but the
//  repository accessors are `nonisolated`: `dbWriter` is a `nonisolated let` (an immutable,
//  `Sendable` `any DatabaseWriter`), so reading it from any isolation domain is safe without
//  `@unchecked Sendable` or `nonisolated(unsafe)` — GRDB's `DatabaseWriter`/`DatabaseReader`
//  protocols are themselves `Sendable`, and the repository structs it hands out are `Sendable`
//  value types that only carry that reference.
//
//  Construct exactly one `AppDatabase` per SQLite file (`SingleOwnerTests`, a later step, makes
//  this a checked discipline; for now it is an invariant this type's shape encodes).
//
//  Migration safety (docs/plans/robust-migration-and-backup.md): `makeShared`/`makeInMemory` take
//  an `eraseDatabaseOnSchemaChange` parameter (default `false`), threaded straight into
//  `SchemaMigrator.migrator(eraseOnSchemaChange:)`. It stays off in normal launch — the app layer
//  only ever flips it on via the explicit `ARI_RESET_STORE=1` opt-in. A second, internal
//  initializer (`init(_:migrator:)`) accepts a caller-supplied `DatabaseMigrator` — a test-only
//  seam (`@testable import AriKit`) letting `MigrationSafetyTests` drive two different migrators
//  against the SAME on-disk file to reproduce/regress the wipe incident, without exposing that
//  seam to feature code outside this module.
//
import Foundation
import GRDB

public actor AppDatabase {
    /// Module-internal (not `private`) so Store-internal tests (`@testable import AriKit`) can
    /// reach the raw writer to exercise FK cascade behavior directly — feature code outside this
    /// module can never see it; only the `public` repository accessors below are exported.
    nonisolated let dbWriter: any DatabaseWriter

    private init(_ dbWriter: any DatabaseWriter, eraseOnSchemaChange: Bool) throws {
        self.dbWriter = dbWriter
        try SchemaMigrator.migrator(eraseOnSchemaChange: eraseOnSchemaChange).migrate(dbWriter)
    }

    /// Test-only seam (`docs/plans/robust-migration-and-backup.md` §7): construct against a
    /// caller-supplied migrator rather than `SchemaMigrator`'s own, so `MigrationSafetyTests` can
    /// drive migrator A/B/C against the same on-disk file. Module-internal, never `public` —
    /// feature code always goes through `makeShared`/`makeInMemory`.
    init(_ dbWriter: any DatabaseWriter, migrator: DatabaseMigrator) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    /// Production: a WAL-mode `DatabasePool` at the app-data path the app resolves. `Store` never
    /// hardcodes or discovers this path itself (never hardcode filesystem paths) — the caller
    /// (app target) resolves it and hands in the `URL`.
    ///
    /// - Parameter eraseDatabaseOnSchemaChange: deliberately OFF by default (2026-07-23 incident
    ///   fix). Only the app layer's explicit `ARI_RESET_STORE=1` opt-in should ever pass `true`.
    public static func makeShared(
        at url: URL,
        eraseDatabaseOnSchemaChange: Bool = false
    ) throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(pool, eraseOnSchemaChange: eraseDatabaseOnSchemaChange)
    }

    /// Tests / SwiftUI previews: an in-memory `DatabaseQueue`, migrated the same way production
    /// is — so schema/round-trip tests exercise the real migrator, not a hand-rolled stand-in.
    public static func makeInMemory(eraseDatabaseOnSchemaChange: Bool = false) throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: configuration)
        return try AppDatabase(queue, eraseOnSchemaChange: eraseDatabaseOnSchemaChange)
    }

    public nonisolated var meetings: MeetingRepository {
        MeetingRepository(dbWriter: dbWriter)
    }

    public nonisolated var transcripts: TranscriptRepository {
        TranscriptRepository(dbWriter: dbWriter)
    }

    public nonisolated var speakers: SpeakerRepository {
        SpeakerRepository(dbWriter: dbWriter)
    }

    public nonisolated var speakerSegments: SpeakerSegmentRepository {
        SpeakerSegmentRepository(dbWriter: dbWriter)
    }

    public nonisolated var persons: PersonRepository {
        PersonRepository(dbWriter: dbWriter)
    }

    public nonisolated var profileFacts: ProfileFactRepository {
        ProfileFactRepository(dbWriter: dbWriter)
    }

    public nonisolated var summaries: SummaryRepository {
        SummaryRepository(dbWriter: dbWriter)
    }

    public nonisolated var meetingNotes: MeetingNoteRepository {
        MeetingNoteRepository(dbWriter: dbWriter)
    }

    public nonisolated var series: SeriesRepository {
        SeriesRepository(dbWriter: dbWriter)
    }

    public nonisolated var calendarEvents: CalendarEventRepository {
        CalendarEventRepository(dbWriter: dbWriter)
    }

    public nonisolated var recallIndex: RecallIndexRepository {
        RecallIndexRepository(dbWriter: dbWriter)
    }

    public nonisolated var askConversations: AskConversationStore {
        AskConversationStore(dbWriter: dbWriter)
    }

    public nonisolated var settings: SettingsRepository {
        SettingsRepository(dbWriter: dbWriter)
    }

    public nonisolated var vocabulary: VocabularyRepository {
        VocabularyRepository(dbWriter: dbWriter)
    }
}
