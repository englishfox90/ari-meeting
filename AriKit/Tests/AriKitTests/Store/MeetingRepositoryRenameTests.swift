//
//  MeetingRepositoryRenameTests.swift — direct coverage of `MeetingRepository.rename`
//  (in-place title update; contrast `upsert`, which resets the tombstone).
//
import Foundation
import Testing
@testable import AriKit

@Suite("MeetingRepository.rename")
struct MeetingRepositoryRenameTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(id: MeetingID, title: String, createdAt: Date) -> Meeting {
        Meeting(id: id, title: title, createdAt: createdAt, updatedAt: createdAt)
    }

    @Test("updates the title and updatedAt, leaving createdAt untouched")
    func updatesTitle() async throws {
        let db = try AppDatabase.makeInMemory()
        let id: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: id, title: "Old", createdAt: base))

        let renameDate = base.addingTimeInterval(3600)
        try await db.meetings.rename(id, to: "New", at: renameDate)

        let reloaded = try #require(try await db.meetings.find(id))
        #expect(reloaded.title == "New")
        #expect(reloaded.createdAt == base)
        #expect(reloaded.updatedAt == renameDate)
    }

    @Test("does not resurrect a tombstoned meeting")
    func keepsTombstone() async throws {
        let db = try AppDatabase.makeInMemory()
        let id: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: id, title: "Old", createdAt: base))
        try await db.meetings.softDelete(id, at: base)

        try await db.meetings.rename(id, to: "New", at: base.addingTimeInterval(60))

        // Still tombstoned → excluded from the default (non-deleted) listing.
        let live = try await db.meetings.all()
        #expect(live.isEmpty)
        // But the rename did land on the row.
        let all = try await db.meetings.all(includingDeleted: true)
        #expect(all.first?.title == "New")
    }

    @Test("no-op for a missing meeting")
    func missingMeetingIsNoOp() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.rename("does-not-exist", to: "New", at: base)
        #expect(try await db.meetings.find("does-not-exist") == nil)
    }
}
