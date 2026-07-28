//
//  SummaryContextAssemblerOwnerParticipantTests.swift — regression cover for the owner appearing
//  as their own participant (docs/plans/duplicate-person-merge.md §2): a `meetingParticipant` row
//  that survives a duplicate-person merge (or any other path) onto the owner must never render
//  twice — once as "Owner:" and again in "Participants:".
//
import Foundation
import Testing
@testable import AriKit

@Suite("SummaryContextAssembler — owner excluded from Participants")
struct SummaryContextAssemblerOwnerParticipantTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMeeting(id: String) -> Meeting {
        Meeting(id: MeetingID(id), title: "Fixture meeting", createdAt: epoch, updatedAt: epoch)
    }

    @Test("Owner linked as a meetingParticipant renders ONLY as Owner:, never also under Participants:")
    func ownerNeverDoubleListed() async throws {
        let db = try AppDatabase.makeInMemory()
        let owner = Person(
            id: PersonID("owner-1"),
            displayName: "Paul Fox-Reeks",
            isOwner: true,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(owner)

        let meeting = makeMeeting(id: "m-1")
        try await db.meetings.upsert(meeting)
        // The owner is ALSO linked as a participant — e.g. a `speaker` link that survived a
        // duplicate-person merge (`PersonRepository.merge`) onto the owner.
        try await db.persons.addParticipant(meetingId: meeting.id, personId: owner.id, linkSource: "speaker", at: epoch)

        let block = await SummaryContextAssembler(database: db).contextBlock(for: meeting.id)

        #expect(block.contains("Owner: Paul Fox-Reeks"))
        #expect(!block.contains("Participants:"), "the owner is the only linked person, so no separate section")
        #expect(block.components(separatedBy: "Paul Fox-Reeks").count == 2, "the name appears exactly once")
    }

    @Test("A real (non-owner) participant still renders normally alongside the owner")
    func realParticipantStillRenders() async throws {
        let db = try AppDatabase.makeInMemory()
        let owner = Person(
            id: PersonID("owner-1"), displayName: "Paul Fox-Reeks", isOwner: true, createdAt: epoch, updatedAt: epoch
        )
        let amy = Person(
            id: PersonID("amy-1"), displayName: "Amy Teuscher", isOwner: false, createdAt: epoch, updatedAt: epoch
        )
        try await db.persons.upsert(owner)
        try await db.persons.upsert(amy)

        let meeting = makeMeeting(id: "m-2")
        try await db.meetings.upsert(meeting)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: owner.id, linkSource: "speaker", at: epoch)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: amy.id, linkSource: "calendar", at: epoch)

        let block = await SummaryContextAssembler(database: db).contextBlock(for: meeting.id)

        #expect(block.contains("Owner: Paul Fox-Reeks"))
        #expect(block.contains("Participants:"))
        #expect(block.contains("- Amy Teuscher"))
        #expect(!block.contains("- Paul Fox-Reeks"), "the owner never appears as a participant bullet")
    }
}
