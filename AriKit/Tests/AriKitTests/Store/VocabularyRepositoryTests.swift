//
//  VocabularyRepositoryTests.swift — Store acceptance tests T-S1..T-S7
//  (docs/plans/custom-vocabulary.md §5).
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("VocabularyRepository")
struct VocabularyRepositoryTests {
    private func makeTerm(
        id: String = UUID().uuidString,
        term: String,
        definition: String? = nil,
        alternateForms: [String] = [],
        misheardAs: [String] = [],
        isEnabled: Bool = true,
        now: Date = Date()
    ) -> VocabularyTerm {
        VocabularyTerm(
            id: VocabularyTermID(id),
            term: term,
            definition: definition,
            alternateForms: alternateForms,
            misheardAs: misheardAs,
            isEnabled: isEnabled,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - T-S1

    @Test("T-S1 v5 migration is additive and preserves existing rows")
    func migrationIsAdditiveAndPreservesExistingRows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-migration-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            let pool = try DatabasePool(path: url.path)
            let db = try AppDatabase(pool, migrator: SchemaMigrator.migratorThroughV4())
            try await db.dbWriter.write { conn in
                try conn.execute(
                    sql: """
                    INSERT INTO meeting (id, title, createdAt, updatedAt, isDeleted)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                    arguments: ["m1", "Standup", now, now]
                )
                try conn.execute(
                    sql: """
                    INSERT INTO setting (key, value, updatedAt)
                    VALUES (?, ?, ?)
                    """,
                    arguments: ["summaryProvider", "ollama", now]
                )
            }
        }

        let pool = try DatabasePool(path: url.path)
        let db = try AppDatabase(pool, migrator: SchemaMigrator.migrator())

        let meetingCount = try await db.dbWriter.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM meeting") ?? 0
        }
        #expect(meetingCount == 1)

        let meetingTitle = try await db.dbWriter.read { conn in
            try String.fetchOne(conn, sql: "SELECT title FROM meeting WHERE id = 'm1'")
        }
        #expect(meetingTitle == "Standup")

        let settingValue = try await db.settings.string(forKey: .summaryProvider)
        #expect(settingValue == "ollama")

        let hasVocabularyTable = try await db.dbWriter.read { conn in
            try conn.tableExists("vocabularyTerm")
        }
        #expect(hasVocabularyTable)
    }

    // MARK: - T-S2

    @Test("T-S2 v1_baseline and v2 through v4 are unmodified — v5 is appended, not inserted")
    func v1BaselineAndV2ThroughV4AreUnmodified() throws {
        let migrator = SchemaMigrator.migrator()
        let identifiers = migrator.migrations
        #expect(identifiers == [
            "v1_baseline",
            "v2_recall_chunk_source_kind",
            "v3_ask_message_card",
            "v4_ask_message_cards",
            "v5_vocabulary_term"
        ])

        let throughV4 = SchemaMigrator.migratorThroughV4()
        #expect(throughV4.migrations == [
            "v1_baseline",
            "v2_recall_chunk_source_kind",
            "v3_ask_message_card",
            "v4_ask_message_cards"
        ])
    }

    // MARK: - T-S3

    @Test("T-S3 duplicate normalized term is rejected")
    func duplicateNormalizedTermIsRejected() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.vocabulary.upsert(makeTerm(term: "Arivo"))

        await #expect(throws: VocabularyError.duplicateTerm(" arivo ")) {
            try await db.vocabulary.upsert(makeTerm(term: " arivo "))
        }
        await #expect(throws: VocabularyError.duplicateTerm("ARIVO")) {
            try await db.vocabulary.upsert(makeTerm(term: "ARIVO"))
        }

        let all = try await db.vocabulary.all()
        #expect(all.count == 1)
    }

    // MARK: - T-S4

    @Test("T-S4 soft-deleted term frees its name")
    func softDeletedTermFreesItsName() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = VocabularyTermID(UUID().uuidString)
        try await db.vocabulary.upsert(makeTerm(id: id.rawValue, term: "Arivo"))

        try await db.vocabulary.softDelete(id, at: Date())

        let readdedId = VocabularyTermID(UUID().uuidString)
        try await db.vocabulary.upsert(makeTerm(id: readdedId.rawValue, term: "Arivo"))

        let all = try await db.vocabulary.all()
        #expect(all.count == 1)
        #expect(all.first?.term == "Arivo")
    }

    // MARK: - T-S5

    @Test("T-S5 enabling past the cap throws and mutates nothing")
    func enablingPastTheCapThrows() async throws {
        let db = try AppDatabase.makeInMemory()
        for index in 0..<VocabularyBias.maxEnabledTerms {
            try await db.vocabulary.upsert(makeTerm(term: "Term \(index)"))
        }
        #expect(try await db.vocabulary.enabledCount() == VocabularyBias.maxEnabledTerms)

        await #expect(throws: VocabularyError.capExceeded(limit: VocabularyBias.maxEnabledTerms)) {
            try await db.vocabulary.upsert(makeTerm(term: "One Too Many"))
        }

        let all = try await db.vocabulary.all()
        #expect(all.count == VocabularyBias.maxEnabledTerms)
        #expect(try await db.vocabulary.enabledCount() == VocabularyBias.maxEnabledTerms)

        // Same invariant via setEnabled on an already-existing disabled term.
        let disabledId = VocabularyTermID(UUID().uuidString)
        try await db.vocabulary.upsert(makeTerm(id: disabledId.rawValue, term: "Disabled Term", isEnabled: false))

        await #expect(throws: VocabularyError.capExceeded(limit: VocabularyBias.maxEnabledTerms)) {
            try await db.vocabulary.setEnabled(true, for: disabledId)
        }

        let disabledTerm = try await db.vocabulary.find(disabledId)
        #expect(disabledTerm?.isEnabled == false)
    }

    // MARK: - T-S6

    @Test("T-S6 round trip preserves arrays, including empty and unicode")
    func roundTripPreservesArrays() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = VocabularyTermID(UUID().uuidString)
        let term = makeTerm(
            id: id.rawValue,
            term: "Arivo",
            definition: "makes 🌟 meetings smart",
            alternateForms: ["AriKit", "Ari Kit", "日本語"],
            misheardAs: ["Revo", "Arrivo"]
        )
        try await db.vocabulary.upsert(term)

        let readBack = try await db.vocabulary.find(id)
        #expect(readBack?.alternateForms == ["AriKit", "Ari Kit", "日本語"])
        #expect(readBack?.misheardAs == ["Revo", "Arrivo"])

        let emptyId = VocabularyTermID(UUID().uuidString)
        try await db.vocabulary.upsert(makeTerm(id: emptyId.rawValue, term: "Bare"))
        let emptyReadBack = try await db.vocabulary.find(emptyId)
        #expect(emptyReadBack?.alternateForms == [])
        #expect(emptyReadBack?.misheardAs == [])
    }

    // MARK: - T-S7

    @Test("T-S7 observeAll emits on change")
    func observeAllEmitsOnChange() async throws {
        let db = try AppDatabase.makeInMemory()
        let stream = db.vocabulary.observeAll()
        var iterator = stream.makeAsyncIterator()

        let first = await iterator.next()
        #expect(first == [])

        try await db.vocabulary.upsert(makeTerm(term: "Arivo"))

        var sawUpdate = false
        while let next = await iterator.next() {
            if next.contains(where: { $0.term == "Arivo" }) {
                sawUpdate = true
                break
            }
        }
        #expect(sawUpdate)
    }
}
