//
//  HomeViewModelTests.swift — loaded + recent-limit/order, honest `.empty`, honest `.failed`,
//  and the real meeting/person counts (home + left-rail rework).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("HomeViewModel")
@MainActor
struct HomeViewModelTests {

    @Test("honest empty on a genuinely empty library")
    func honestEmpty() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = HomeViewModel(database: database)
        await viewModel.observe()
        guard case .empty = viewModel.state else {
            Issue.record("expected .empty, got \(viewModel.state)")
            return
        }
        #expect(viewModel.meetingCount == 0)
        #expect(viewModel.personCount == 0)
    }

    @Test("recent meetings ordered createdAt desc, bounded to the recent limit")
    func recentOrderedAndBounded() async throws {
        let database = try AppDatabase.makeInMemory()
        // One more than the recent limit, so the bound is actually exercised.
        let total = HomeViewModel.recentLimit + 1
        var meetings: [Meeting] = []
        for index in 0 ..< total {
            let meeting = HomeViewModelTests.makeMeeting(
                id: "meeting-\(index)",
                createdAt: 1_700_000_000 + TimeInterval(index * 3600)
            )
            meetings.append(meeting)
            try await database.meetings.upsert(meeting)
        }

        let viewModel = HomeViewModel(database: database)
        await viewModel.observe()

        guard case let .loaded(recent) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(recent.count == HomeViewModel.recentLimit)
        let expectedIds = meetings.reversed().prefix(HomeViewModel.recentLimit).map(\.id)
        #expect(recent.map(\.id) == Array(expectedIds))
        // meetingCount is the real, unbounded library size — not the display-bounded list.
        #expect(viewModel.meetingCount == total)
    }

    @Test("real person count")
    func realPersonCount() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await database.persons.upsert(
            Person(id: "person-owner", displayName: "Paul Owner", isOwner: true, createdAt: now, updatedAt: now)
        )
        try await database.persons.upsert(
            Person(id: "person-guest", displayName: "Ada Lovelace", isOwner: false, createdAt: now, updatedAt: now)
        )

        let viewModel = HomeViewModel(database: database)
        await viewModel.observe()

        #expect(viewModel.personCount == 2)
    }

    @Test("honest failed on a real read error")
    func honestFailed() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.dbWriter.write { db in
            try db.execute(sql: "DROP TABLE meeting")
        }

        let viewModel = HomeViewModel(database: database)
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
