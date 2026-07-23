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
}
