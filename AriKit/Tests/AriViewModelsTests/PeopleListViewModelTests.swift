//
//  PeopleListViewModelTests.swift — loaded (owner flagged), honest `.empty`, honest `.failed`
//  (docs/plans/arikit-native-read-ui.md §7 Lane 1, S6e).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("PeopleListViewModel")
@MainActor
struct PeopleListViewModelTests {

    @Test("honest empty on a genuinely empty roster")
    func honestEmpty() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = PeopleListViewModel(database: database)
        await viewModel.observe()
        guard case .empty = viewModel.state else {
            Issue.record("expected .empty, got \(viewModel.state)")
            return
        }
    }

    @Test("loaded people, owner flagged")
    func loadedOwnerFlagged() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let owner = Person(
            id: "person-owner", displayName: "Paul Owner", isOwner: true,
            createdAt: now, updatedAt: now
        )
        let guest = Person(
            id: "person-guest", displayName: "Ada Lovelace", isOwner: false,
            createdAt: now, updatedAt: now
        )
        try await database.persons.upsert(owner)
        try await database.persons.upsert(guest)

        let viewModel = PeopleListViewModel(database: database)
        await viewModel.observe()

        guard case let .loaded(people) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(people.first(where: { $0.id == owner.id })?.isOwner == true)
        #expect(people.first(where: { $0.id == guest.id })?.isOwner == false)
    }

    @Test("honest failed on a real read error")
    func honestFailed() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.dbWriter.write { db in
            try db.execute(sql: "DROP TABLE person")
        }

        let viewModel = PeopleListViewModel(database: database)
        await viewModel.observe()

        guard case let .failed(message) = viewModel.state else {
            Issue.record("expected .failed, got \(viewModel.state)")
            return
        }
        #expect(!message.isEmpty)
    }
}
