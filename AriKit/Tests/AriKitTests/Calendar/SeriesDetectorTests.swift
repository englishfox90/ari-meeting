//
//  SeriesDetectorTests.swift — F9 series auto-detection, consent-aware (calendar-series-
//  intelligence plan §5, tests 7-13). Parity + the consent divergence, driven directly against
//  `SeriesDetector.detect` with hand-built `CalendarEvent`s (no sync engine involved here — see
//  `CalendarSyncEngineTests` for the wiring tests, 14-16).
//
import Foundation
import Testing
@testable import AriKit

@Suite("SeriesDetector")
struct SeriesDetectorTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(id: String, createdAt: Date) -> Meeting {
        Meeting(id: MeetingID(id), title: "Meeting \(id)", createdAt: createdAt, updatedAt: createdAt)
    }

    private func event(
        id: String = "ev-1",
        title: String = "Weekly Sync",
        meetingId: MeetingID? = nil,
        hasRecurrence: Bool? = true,
        seriesKey: String? = "series-key-1",
        occurrenceDate: Date? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: CalendarEventID(id),
            calendarId: "cal-1",
            title: title,
            startTime: epoch,
            endTime: epoch.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [],
            meetingId: meetingId,
            seriesKey: seriesKey,
            hasRecurrence: hasRecurrence,
            occurrenceDate: occurrenceDate
        )
    }

    private func setAutoAddMode(_ db: AppDatabase, seriesId: SeriesID, mode: String) async throws {
        try await db.dbWriter.write { conn in
            guard var record = try SeriesRecord.fetchOne(conn, key: seriesId.rawValue) else { return }
            record.autoAddMode = mode
            try record.update(conn)
        }
    }

    private func memberRecord(
        _ db: AppDatabase, seriesId: SeriesID, meetingId: MeetingID
    ) async throws -> SeriesMemberRecord? {
        try await db.dbWriter.read { conn in
            try SeriesMemberRecord.fetchOne(
                conn, key: ["seriesId": seriesId.rawValue, "meetingId": meetingId.rawValue]
            )
        }
    }

    // MARK: - 7. Guards

    @Test("guards no-op: unlinked / no recurrence / nil or blank seriesKey — zero rows written")
    func guardsNoOp() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = meeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        let detector = SeriesDetector(database: db)

        let cases: [CalendarEvent] = [
            event(meetingId: nil), // unlinked
            event(meetingId: m1.id, hasRecurrence: false),
            event(meetingId: m1.id, hasRecurrence: nil),
            event(meetingId: m1.id, seriesKey: nil),
            event(meetingId: m1.id, seriesKey: "   ")
        ]

        for c in cases {
            #expect(try await detector.detect(for: c, at: epoch) == .skipped)
        }

        #expect(try await db.series.all().isEmpty)
    }

    // MARK: - 8. First detection

    @Test("first detection creates a series and one 'suggested' member; occurrenceTime prefers occurrenceDate")
    func firstDetectionCreatesSeriesAndSuggestedMember() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = meeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        let occurrence = epoch.addingTimeInterval(3600)

        let detector = SeriesDetector(database: db)
        let outcome = try await detector.detect(
            for: event(meetingId: m1.id, occurrenceDate: occurrence), at: epoch
        )

        guard case let .suggested(seriesId) = outcome else {
            Issue.record("expected .suggested, got \(outcome)")
            return
        }

        let series = try await db.series.find(seriesId)
        #expect(series?.title == "Weekly Sync")
        #expect(series?.seriesKey == "series-key-1")

        let record = try await db.dbWriter.read { try SeriesRecord.fetchOne($0, key: seriesId.rawValue) }
        #expect(record?.autoAddMode == "ask")

        let member = try await memberRecord(db, seriesId: seriesId, meetingId: m1.id)
        #expect(member?.linkSource == "suggested")
        #expect(member?.occurrenceTime == RFC3339.string(from: occurrence))
    }

    @Test("a blank event title falls back to 'Recurring meeting'")
    func blankTitleFallsBack() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = meeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        let detector = SeriesDetector(database: db)

        let outcome = try await detector.detect(for: event(title: "  ", meetingId: m1.id), at: epoch)
        guard case let .suggested(seriesId) = outcome else {
            Issue.record("expected .suggested, got \(outcome)")
            return
        }
        let series = try await db.series.find(seriesId)
        #expect(series?.title == "Recurring meeting")
    }

    // MARK: - 9. Idempotency

    @Test("second run for the same key/meeting is idempotent — no duplicate series, no member churn")
    func idempotentSecondRun() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = meeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        let detector = SeriesDetector(database: db)

        let first = try await detector.detect(for: event(meetingId: m1.id), at: epoch)
        guard case let .suggested(seriesId) = first else {
            Issue.record("expected .suggested, got \(first)")
            return
        }

        let second = try await detector.detect(for: event(meetingId: m1.id), at: epoch.addingTimeInterval(60))
        #expect(second == .skipped)

        #expect(try await db.series.all().count == 1)
        #expect(try await db.series.suggestedMeetingIds(inSeries: seriesId) == [m1.id])
    }

    // MARK: - 10. Manual membership never overwritten

    @Test("an existing 'manual' membership is never overwritten (divergence from Rust)")
    func existingManualMembershipNeverOverwritten() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = meeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        try await db.dbWriter.write { conn in
            guard var record = try SeriesRecord.fetchOne(conn, key: seriesId.rawValue) else { return }
            record.seriesKey = "series-key-1"
            try record.update(conn)
        }
        try await db.series.addMember(seriesId: seriesId, meetingId: m1.id, linkSource: "manual", at: epoch)

        let detector = SeriesDetector(database: db)
        let outcome = try await detector.detect(for: event(meetingId: m1.id), at: epoch)

        #expect(outcome == .skipped)
        let member = try await memberRecord(db, seriesId: seriesId, meetingId: m1.id)
        #expect(member?.linkSource == "manual")
    }

    // MARK: - 11/12. autoAddMode 'always'/'never'

    @Test("autoAddMode 'always' auto-adds with linkSource 'auto'")
    func autoAddModeAlwaysAutoAdds() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = meeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        try await db.dbWriter.write { conn in
            guard var record = try SeriesRecord.fetchOne(conn, key: seriesId.rawValue) else { return }
            record.seriesKey = "series-key-1"
            try record.update(conn)
        }
        try await setAutoAddMode(db, seriesId: seriesId, mode: "always")

        let detector = SeriesDetector(database: db)
        let outcome = try await detector.detect(for: event(meetingId: m1.id), at: epoch)

        #expect(outcome == .autoAdded(seriesId))
        let member = try await memberRecord(db, seriesId: seriesId, meetingId: m1.id)
        #expect(member?.linkSource == "auto")
    }

    @Test("autoAddMode 'never' skips, writing nothing")
    func autoAddModeNeverSkips() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = meeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        try await db.dbWriter.write { conn in
            guard var record = try SeriesRecord.fetchOne(conn, key: seriesId.rawValue) else { return }
            record.seriesKey = "series-key-1"
            try record.update(conn)
        }
        try await setAutoAddMode(db, seriesId: seriesId, mode: "never")

        let detector = SeriesDetector(database: db)
        let outcome = try await detector.detect(for: event(meetingId: m1.id), at: epoch)

        #expect(outcome == .skipped)
        let member = try await memberRecord(db, seriesId: seriesId, meetingId: m1.id)
        #expect(member == nil)
    }

    // MARK: - 13. Tombstoned series holds the key

    @Test("a tombstoned series holding the key is never resurrected")
    func tombstonedSeriesNeverResurrected() async throws {
        let db = try AppDatabase.makeInMemory()
        let m1 = meeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)

        let deletedId = try await db.series.createSeries(title: "Old series", at: epoch)
        try await db.dbWriter.write { conn in
            guard var record = try SeriesRecord.fetchOne(conn, key: deletedId.rawValue) else { return }
            record.seriesKey = "series-key-1"
            record.isDeleted = true
            record.deletedAt = epoch
            try record.update(conn)
        }

        let detector = SeriesDetector(database: db)
        let outcome = try await detector.detect(for: event(meetingId: m1.id), at: epoch.addingTimeInterval(60))

        #expect(outcome == .skipped)
        #expect(try await db.series.all().isEmpty)
        #expect(try await db.series.all(includingDeleted: true).count == 1)
        let member = try await memberRecord(db, seriesId: deletedId, meetingId: m1.id)
        #expect(member == nil)
    }
}
