//
//  SettingsRepositoryTests.swift — round-trip + honest-absence coverage for `SettingsRepository`
//  (docs/plans/settings-ui.md §8 test 1).
//
import Foundation
import Testing
@testable import AriKit

@Suite("SettingsRepository")
struct SettingsRepositoryTests {
    @Test("string round-trips")
    func stringRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setString("ollama", forKey: .summaryProvider)
        let value = try await db.settings.string(forKey: .summaryProvider)
        #expect(value == "ollama")
    }

    @Test("bool round-trips")
    func boolRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setBool(true, forKey: .recordingsSaveAudio)
        let value = try await db.settings.bool(forKey: .recordingsSaveAudio)
        #expect(value == true)

        try await db.settings.setBool(false, forKey: .recordingsSaveAudio)
        let updated = try await db.settings.bool(forKey: .recordingsSaveAudio)
        #expect(updated == false)
    }

    @Test("int round-trips")
    func intRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setInt(42, forKey: .summaryAutomatic)
        let value = try await db.settings.int(forKey: .summaryAutomatic)
        #expect(value == 42)
    }

    @Test("unknown key returns nil, never a fabricated default")
    func unknownKeyReturnsNil() async throws {
        let db = try AppDatabase.makeInMemory()
        let stringValue = try await db.settings.string(forKey: .transcriptionProvider)
        let boolValue = try await db.settings.bool(forKey: .generalRecordingAlerts)
        let intValue = try await db.settings.int(forKey: .summaryAutomatic)
        #expect(stringValue == nil)
        #expect(boolValue == nil)
        #expect(intValue == nil)
    }

    @Test("remove deletes the row")
    func removeDeletesRow() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setString("parakeet", forKey: .transcriptionProvider)
        try await db.settings.remove(forKey: .transcriptionProvider)
        let value = try await db.settings.string(forKey: .transcriptionProvider)
        #expect(value == nil)
    }

    @Test("all() returns exactly the stored keys")
    func allReturnsExactSet() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.settings.setString("ollama", forKey: .summaryProvider)
        try await db.settings.setString("http://localhost:11434", forKey: .summaryOllamaEndpoint)

        let all = try await db.settings.all()
        #expect(all == [
            SettingKey.summaryProvider.rawValue: "ollama",
            SettingKey.summaryOllamaEndpoint.rawValue: "http://localhost:11434"
        ])
    }

    @Test("updatedAt is stamped on write")
    func updatedAtStamped() async throws {
        let db = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.settings.setString("value", forKey: .summaryLanguage, now: now)

        let record = try await db.dbWriter.read { dbConn in
            try SettingRecord.fetchOne(dbConn, key: SettingKey.summaryLanguage.rawValue)
        }
        #expect(record?.updatedAt == now)
    }

    @Test("observeString yields live updates")
    func observeStringYieldsUpdates() async throws {
        let db = try AppDatabase.makeInMemory()
        let stream = db.settings.observeString(forKey: .summaryProvider)
        var iterator = stream.makeAsyncIterator()

        let first = await iterator.next()
        #expect(first == String??.some(nil))

        try await db.settings.setString("ollama", forKey: .summaryProvider)

        var sawUpdate = false
        while let next = await iterator.next() {
            if next == "ollama" {
                sawUpdate = true
                break
            }
        }
        #expect(sawUpdate)
    }
}
