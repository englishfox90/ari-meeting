//
//  PersonDetailViewModelTests.swift — resolve; honest-empty participant meetings (no reverse
//  query exists yet — see PersonDetailViewModel's file-header TODO(S6))
//  (docs/plans/arikit-native-read-ui.md §7 Lane 1, S6e).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("PersonDetailViewModel")
@MainActor
struct PersonDetailViewModelTests {

    @Test("resolves an authored person")
    func resolvesPerson() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let personId: PersonID = "person-1"
        let person = Person(
            id: personId, displayName: "Ada Lovelace", isOwner: false,
            createdAt: now, updatedAt: now
        )
        try await database.persons.upsert(person)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        #expect(viewModel.person.value?.id == personId)
        #expect(viewModel.person.value?.displayName == "Ada Lovelace")
    }

    @Test("honest empty participant meetings — no reverse query exists")
    func honestEmptyParticipantMeetings() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let personId: PersonID = "person-2"
        let person = Person(
            id: personId, displayName: "Ada Lovelace", isOwner: false,
            createdAt: now, updatedAt: now
        )
        try await database.persons.upsert(person)

        // Even with a real participant link, the view model does not fabricate a meetings
        // list — it stays honestly empty until a real person→meetings query exists.
        let meetingId: MeetingID = "meeting-1"
        let meeting = Meeting(id: meetingId, title: "1:1", createdAt: now, updatedAt: now)
        try await database.meetings.upsert(meeting)
        try await database.persons.addParticipant(meetingId: meetingId, personId: personId)

        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load(personId)

        #expect(viewModel.person.value?.id == personId)
        #expect(viewModel.participantMeetings.isEmpty)
    }

    @Test("honest failed when the person does not exist")
    func honestFailedOnMissingPerson() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = PersonDetailViewModel(database: database)
        await viewModel.load("does-not-exist")

        guard case .failed = viewModel.person else {
            Issue.record("expected .failed, got \(viewModel.person)")
            return
        }
    }
}
