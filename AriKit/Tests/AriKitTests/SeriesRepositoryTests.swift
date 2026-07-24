//
//  SeriesRepositoryTests.swift — F9 series management additions: createSeries / rename / merge /
//  deleteSeries / orderedMeetingIds.
//
import Foundation
import Testing
@testable import AriKit

@Suite("SeriesRepository (F9 series management)")
struct SeriesRepositoryTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMeeting(id: String, createdAt: Date) -> Meeting {
        Meeting(id: MeetingID(id), title: "Meeting \(id)", createdAt: createdAt, updatedAt: createdAt)
    }

    @Test("createSeries creates a findable series")
    func createSeriesCreatesFindableSeries() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = try await db.series.createSeries(title: "Brian 1:1", at: epoch)

        let found = try await db.series.find(id)
        #expect(found?.title == "Brian 1:1")
        #expect(found?.ledgerMarkdown == nil)
    }

    @Test("rename preserves an existing ledger")
    func renamePreservesExistingLedger() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        try await db.series.updateLedger(
            seriesId: id,
            ledgerMarkdown: "- Open: ship the thing.",
            structuredJson: nil,
            updatedFromMeetingId: nil,
            ledgerVersion: 1,
            at: epoch
        )

        try await db.series.rename(id, to: "Brian Sync", at: epoch.addingTimeInterval(60))

        let found = try await db.series.find(id)
        #expect(found?.title == "Brian Sync")
        #expect(found?.ledgerMarkdown == "- Open: ship the thing.")
        #expect(found?.ledgerVersion == 1)
    }

    @Test("merge moves and de-dupes members and tombstones the source")
    func mergeMovesAndDeDupesMembersAndTombstonesSource() async throws {
        let db = try AppDatabase.makeInMemory()

        let source = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        let target = try await db.series.createSeries(title: "Brian Sync", at: epoch)

        let m1 = makeMeeting(id: "m1", createdAt: epoch)
        let m2 = makeMeeting(id: "m2", createdAt: epoch.addingTimeInterval(1000))
        // Shared meeting — already in both series before the merge, must not duplicate.
        let shared = makeMeeting(id: "shared", createdAt: epoch.addingTimeInterval(2000))
        try await db.meetings.upsert(m1)
        try await db.meetings.upsert(m2)
        try await db.meetings.upsert(shared)

        try await db.series.addMember(seriesId: source, meetingId: m1.id, at: epoch)
        try await db.series.addMember(seriesId: source, meetingId: shared.id, at: epoch)
        try await db.series.addMember(seriesId: target, meetingId: m2.id, at: epoch)
        try await db.series.addMember(seriesId: target, meetingId: shared.id, at: epoch)

        try await db.series.merge(source: source, into: target, at: epoch.addingTimeInterval(3000))

        let targetMembers = try await Set(db.series.meetingIds(inSeries: target))
        #expect(targetMembers == Set([m1.id, m2.id, shared.id]))

        let sourceMembers = try await db.series.meetingIds(inSeries: source)
        #expect(sourceMembers.isEmpty)

        // Source is tombstoned (excluded from a non-including-deleted read).
        let allNonDeleted = try await db.series.all()
        #expect(!allNonDeleted.contains { $0.id == source })
        let allIncludingDeleted = try await db.series.all(includingDeleted: true)
        #expect(allIncludingDeleted.first { $0.id == source }?.title == "Brian 1:1")
    }

    @Test("merge is a no-op when source == target")
    func mergeNoOpWhenSourceEqualsTarget() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        let m1 = makeMeeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        try await db.series.addMember(seriesId: id, meetingId: m1.id, at: epoch)

        try await db.series.merge(source: id, into: id, at: epoch)

        let found = try await db.series.find(id)
        #expect(found != nil)
        #expect(try await db.series.meetingIds(inSeries: id) == [m1.id])
    }

    @Test("deleteSeries detaches members and tombstones the series")
    func deleteSeriesDetachesMembersAndTombstones() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        let m1 = makeMeeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        try await db.series.addMember(seriesId: id, meetingId: m1.id, at: epoch)

        try await db.series.deleteSeries(id, at: epoch.addingTimeInterval(60))

        #expect(try await db.series.meetingIds(inSeries: id).isEmpty)
        #expect(try await db.series.seriesIds(forMeeting: m1.id).isEmpty)
        let allNonDeleted = try await db.series.all()
        #expect(!allNonDeleted.contains { $0.id == id })
    }

    @Test("orderedMeetingIds sorts chronologically by meeting time, not link-creation order")
    func orderedMeetingIdsSortsChronologically() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = try await db.series.createSeries(title: "Brian 1:1", at: epoch)

        let early = makeMeeting(id: "early", createdAt: epoch)
        let middle = makeMeeting(id: "middle", createdAt: epoch.addingTimeInterval(1000))
        let late = makeMeeting(id: "late", createdAt: epoch.addingTimeInterval(2000))
        try await db.meetings.upsert(late)
        try await db.meetings.upsert(early)
        try await db.meetings.upsert(middle)

        // Add members in a deliberately non-chronological link order.
        try await db.series.addMember(seriesId: id, meetingId: late.id, at: epoch)
        try await db.series.addMember(seriesId: id, meetingId: early.id, at: epoch.addingTimeInterval(1))
        try await db.series.addMember(seriesId: id, meetingId: middle.id, at: epoch.addingTimeInterval(2))

        let ordered = try await db.series.orderedMeetingIds(inSeries: id)
        #expect(ordered == [early.id, middle.id, late.id])
    }

    // MARK: - Suggestion semantics (calendar-series-intelligence plan §5, tests 17-19)

    @Test("'suggested' rows are excluded from content reads but returned by suggestedSeriesIds")
    func suggestedRowsExcludedFromContentReads() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = try await db.series.createSeries(title: "Brian 1:1", at: epoch)

        let suggested = makeMeeting(id: "suggested", createdAt: epoch)
        let real = makeMeeting(id: "real", createdAt: epoch.addingTimeInterval(1000))
        try await db.meetings.upsert(suggested)
        try await db.meetings.upsert(real)

        try await db.series.addMember(
            seriesId: id, meetingId: suggested.id, linkSource: "suggested", at: epoch
        )
        try await db.series.addMember(seriesId: id, meetingId: real.id, linkSource: "manual", at: epoch)

        #expect(try await db.series.meetingIds(inSeries: id) == [real.id])
        #expect(try await db.series.seriesIds(forMeeting: suggested.id).isEmpty)
        #expect(try await db.series.seriesIds(forMeeting: real.id) == [id])
        #expect(try await db.series.orderedMeetingIds(inSeries: id) == [real.id])

        let summaries = try await db.series.allSummaries()
        #expect(summaries.first { $0.id == id }?.meetingCount == 1)

        // But visible through the dedicated suggestion reads.
        #expect(try await db.series.suggestedSeriesIds(forMeeting: suggested.id) == [id])
        #expect(try await db.series.suggestedMeetingIds(inSeries: id) == [suggested.id])
    }

    @Test("confirmSuggestedMember flips linkSource to 'auto', sets autoAddMode 'always', and joins the citation index")
    func confirmSuggestedMemberAtomicTransition() async throws {
        let db = try AppDatabase.makeInMemory()
        let id = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        let m1 = makeMeeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        try await db.series.addMember(seriesId: id, meetingId: m1.id, linkSource: "suggested", at: epoch)

        #expect(try await db.series.orderedMeetingIds(inSeries: id).isEmpty)

        try await db.series.confirmSuggestedMember(seriesId: id, meetingId: m1.id, at: epoch.addingTimeInterval(60))

        #expect(try await db.series.suggestedSeriesIds(forMeeting: m1.id).isEmpty)
        #expect(try await db.series.seriesIds(forMeeting: m1.id) == [id])
        #expect(try await db.series.orderedMeetingIds(inSeries: id) == [m1.id])

        // autoAddMode is Store-internal — confirm the "remembered choice" via a second detection
        // run through the raw record (module-internal access under @testable import).
        let record = try await db.dbWriter.read { try SeriesRecord.fetchOne($0, key: id.rawValue) }
        #expect(record?.autoAddMode == "always")
    }

    @Test("declineSuggestedMember deletes the row, sets autoAddMode 'never', and tombstones a now-empty series")
    func declineSuggestedMemberDeletesAndTombstonesWhenEmpty() async throws {
        let db = try AppDatabase.makeInMemory()

        // Series left with zero members after decline → tombstoned.
        let onlySuggestion = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        let m1 = makeMeeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(m1)
        try await db.series.addMember(
            seriesId: onlySuggestion, meetingId: m1.id, linkSource: "suggested", at: epoch
        )

        try await db.series.declineSuggestedMember(
            seriesId: onlySuggestion, meetingId: m1.id, at: epoch.addingTimeInterval(60)
        )

        #expect(try await db.series.suggestedSeriesIds(forMeeting: m1.id).isEmpty)
        let live = try await db.series.all()
        #expect(!live.contains { $0.id == onlySuggestion })
        let record = try await db.dbWriter.read { try SeriesRecord.fetchOne($0, key: onlySuggestion.rawValue) }
        #expect(record?.autoAddMode == "never")
        #expect(record?.isDeleted == true)

        // Series with other real members is not tombstoned.
        let withRealMember = try await db.series.createSeries(title: "Hailey Sync", at: epoch)
        let m2 = makeMeeting(id: "m2", createdAt: epoch)
        let m3 = makeMeeting(id: "m3", createdAt: epoch.addingTimeInterval(1000))
        try await db.meetings.upsert(m2)
        try await db.meetings.upsert(m3)
        try await db.series.addMember(seriesId: withRealMember, meetingId: m2.id, linkSource: "manual", at: epoch)
        try await db.series.addMember(
            seriesId: withRealMember, meetingId: m3.id, linkSource: "suggested", at: epoch
        )

        try await db.series.declineSuggestedMember(seriesId: withRealMember, meetingId: m3.id, at: epoch)

        let stillLive = try await db.series.all()
        #expect(stillLive.contains { $0.id == withRealMember })
        #expect(try await db.series.meetingIds(inSeries: withRealMember) == [m2.id])
    }

    // MARK: - M2: insertMemberIfAbsent is check-then-act in ONE transaction

    @Test("insertMemberIfAbsent: the second call for the same (series, meeting) returns false and writes nothing")
    func insertMemberIfAbsentSecondCallReturnsFalseAndWritesNothing() async throws {
        let db = try AppDatabase.makeInMemory()
        let seriesId = try await db.series.createSeries(title: "Brian 1:1", at: epoch)
        let meeting = makeMeeting(id: "m1", createdAt: epoch)
        try await db.meetings.upsert(meeting)

        let firstWrote = try await db.series.insertMemberIfAbsent(
            seriesId: seriesId, meetingId: meeting.id,
            occurrenceTime: "2026-07-01T09:00:00Z", linkSource: "suggested", at: epoch
        )
        #expect(firstWrote == true)

        let secondWrote = try await db.series.insertMemberIfAbsent(
            seriesId: seriesId, meetingId: meeting.id,
            occurrenceTime: "2026-07-08T09:00:00Z", linkSource: "auto", at: epoch.addingTimeInterval(60)
        )
        #expect(secondWrote == false)

        // Nothing changed: still exactly one membership row, and it's untouched — `linkSource`
        // wasn't overwritten to "auto" by the second (no-op) call.
        let record = try await db.dbWriter.read { db in
            try SeriesMemberRecord.fetchOne(
                db, key: ["seriesId": seriesId.rawValue, "meetingId": meeting.id.rawValue]
            )
        }
        #expect(record?.linkSource == "suggested")
        #expect(record?.occurrenceTime == "2026-07-01T09:00:00Z")
    }
}
