//
//  MeetingRepositoryClosestMeetingIDTests.swift — direct coverage of
//  `MeetingRepository.closestMeetingID` (docs/plans/arikit-calendar.md §2.3, the calendar
//  auto-match query, parity: `calendar.rs:399-423`).
//
import Foundation
import Testing
@testable import AriKit

@Suite("MeetingRepository.closestMeetingID")
struct MeetingRepositoryClosestMeetingIDTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(id: MeetingID, createdAt: Date) -> Meeting {
        Meeting(id: id, title: "Recording", createdAt: createdAt, updatedAt: createdAt)
    }

    @Test("returns the meeting whose createdAt is closest to the anchor")
    func returnsClosestMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        let far: MeetingID = "meeting-far"
        let near: MeetingID = "meeting-near"
        try await db.meetings.upsert(meeting(id: far, createdAt: base.addingTimeInterval(-600)))
        try await db.meetings.upsert(meeting(id: near, createdAt: base.addingTimeInterval(-120)))

        let result = try await db.meetings.closestMeetingID(
            createdBetween: base.addingTimeInterval(-900), and: base.addingTimeInterval(900), to: base
        )
        #expect(result == near)
    }

    @Test("returns nil when no meeting falls in the window")
    func returnsNilWhenNoneInWindow() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(meeting(id: "meeting-1", createdAt: base.addingTimeInterval(-3600)))

        let result = try await db.meetings.closestMeetingID(
            createdBetween: base.addingTimeInterval(-900), and: base.addingTimeInterval(900), to: base
        )
        #expect(result == nil)
    }

    @Test("excludes tombstoned meetings")
    func excludesTombstonedMeetings() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base.addingTimeInterval(-60)))
        try await db.meetings.softDelete(meetingId, at: base)

        let result = try await db.meetings.closestMeetingID(
            createdBetween: base.addingTimeInterval(-900), and: base.addingTimeInterval(900), to: base
        )
        #expect(result == nil)
    }
}
