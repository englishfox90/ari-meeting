//
//  MeetingsListViewModelTests.swift — loaded/order, honest `.empty`, honest `.failed`
//  (docs/plans/arikit-native-read-ui.md §7 Lane 1).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("MeetingsListViewModel")
@MainActor
struct MeetingsListViewModelTests {

    @Test("honest empty on a genuinely empty library")
    func honestEmpty() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = MeetingsListViewModel(database: database)
        await viewModel.observe()
        #expect(viewModel.state.value == nil)
        guard case .empty = viewModel.state else {
            Issue.record("expected .empty, got \(viewModel.state)")
            return
        }
    }

    @Test("loaded meetings ordered createdAt desc")
    func loadedOrderedDescending() async throws {
        let database = try AppDatabase.makeInMemory()
        let earlier = MeetingsListViewModelTests.makeMeeting(id: "meeting-1", createdAt: 1_700_000_000)
        let later = MeetingsListViewModelTests.makeMeeting(id: "meeting-2", createdAt: 1_700_003_600)
        try await database.meetings.upsert(earlier)
        try await database.meetings.upsert(later)

        let viewModel = MeetingsListViewModel(database: database)
        await viewModel.observe()

        guard case let .loaded(meetings) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(meetings.map(\.id) == [later.id, earlier.id])
    }

    @Test("honest failed on a real read error")
    func honestFailed() async throws {
        let database = try AppDatabase.makeInMemory()
        // Force a real read failure: drop the backing table out from under the repository.
        try await database.dbWriter.write { db in
            try db.execute(sql: "DROP TABLE meeting")
        }

        let viewModel = MeetingsListViewModel(database: database)
        await viewModel.observe()

        guard case let .failed(message) = viewModel.state else {
            Issue.record("expected .failed, got \(viewModel.state)")
            return
        }
        #expect(!message.isEmpty)
    }

    private static func makeMeeting(id: String, createdAt: TimeInterval) -> Meeting {
        Meeting(
            id: MeetingID(id),
            title: "Meeting \(id)",
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
