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
import Foundation
import GRDB

public actor AppDatabase {
    /// Module-internal (not `private`) so Store-internal tests (`@testable import AriKit`) can
    /// reach the raw writer to exercise FK cascade behavior directly — feature code outside this
    /// module can never see it; only the `public` repository accessors below are exported.
    nonisolated let dbWriter: any DatabaseWriter

    private init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try SchemaMigrator.migrator.migrate(dbWriter)
    }

    /// Production: a WAL-mode `DatabasePool` at the app-data path the app resolves. `Store` never
    /// hardcodes or discovers this path itself (never hardcode filesystem paths) — the caller
    /// (app target) resolves it and hands in the `URL`.
    public static func makeShared(at url: URL) throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(pool)
    }

    /// Tests / SwiftUI previews: an in-memory `DatabaseQueue`, migrated the same way production
    /// is — so schema/round-trip tests exercise the real migrator, not a hand-rolled stand-in.
    public static func makeInMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: configuration)
        return try AppDatabase(queue)
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
}
