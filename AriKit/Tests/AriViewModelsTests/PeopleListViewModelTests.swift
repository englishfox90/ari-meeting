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

    // MARK: - Slice 3 (docs/plans/people-view-parity.md §5 test 14)

    @Test("the owner is excluded from `filtered`")
    func ownerExcludedFromFiltered() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let owner = Person(
            id: "person-owner", displayName: "Paul Owner", isOwner: true, createdAt: now, updatedAt: now
        )
        let guest = Person(
            id: "person-guest", displayName: "Ada Lovelace", isOwner: false, createdAt: now, updatedAt: now
        )
        try await database.persons.upsert(owner)
        try await database.persons.upsert(guest)

        let viewModel = PeopleListViewModel(database: database)
        await viewModel.observe()

        #expect(viewModel.filtered.map(\.id) == [guest.id])
    }

    @Test("searchText filters by name/email/role; hasNoMatches distinguishes a miss from an empty roster")
    func searchFiltersByNameEmailRole() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await database.persons.upsert(Person(
            id: "person-owner", displayName: "Paul Owner", isOwner: true, createdAt: now, updatedAt: now
        ))
        try await database.persons.upsert(Person(
            id: "person-ada", email: "ada@example.com", displayName: "Ada Lovelace", role: "Engineer",
            isOwner: false, createdAt: now, updatedAt: now
        ))
        try await database.persons.upsert(Person(
            id: "person-brian", displayName: "Brian Kernighan", role: "Author",
            isOwner: false, createdAt: now, updatedAt: now
        ))

        let viewModel = PeopleListViewModel(database: database)
        await viewModel.observe()

        #expect(!viewModel.hasNoMatches)

        // Case-insensitive name match.
        viewModel.searchText = "ada"
        #expect(viewModel.filtered.map(\.id) == [PersonID("person-ada")])
        #expect(!viewModel.hasNoMatches)

        // Email match.
        viewModel.searchText = "example.com"
        #expect(viewModel.filtered.map(\.id) == [PersonID("person-ada")])

        // Role match.
        viewModel.searchText = "author"
        #expect(viewModel.filtered.map(\.id) == [PersonID("person-brian")])

        // A miss is an honest no-matches, distinct from a genuinely empty roster.
        viewModel.searchText = "zzz"
        #expect(viewModel.filtered.isEmpty)
        #expect(viewModel.hasNoMatches)

        // Clearing the query restores the full (owner-excluded) roster without a re-read.
        viewModel.searchText = ""
        #expect(Set(viewModel.filtered.map(\.id)) == [PersonID("person-ada"), PersonID("person-brian")])
        #expect(!viewModel.hasNoMatches)
    }

    @Test("saveOwner creates a new owner, then persists edits to the existing owner")
    func saveOwnerPersistsAndRefreshes() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = PeopleListViewModel(database: database)
        await viewModel.observe()
        #expect(viewModel.owner == nil)

        await viewModel.saveOwner(
            displayName: "Paul Fox-Reeks", email: "paul@example.com", role: "Founder",
            organization: "Arivo", domain: "Product", notes: "Owner notes"
        )

        #expect(viewModel.owner?.displayName == "Paul Fox-Reeks")
        #expect(viewModel.owner?.email == "paul@example.com")
        #expect(viewModel.owner?.isOwner == true)
        let ownerId = try #require(viewModel.owner?.id)

        // Editing preserves the same id/isOwner (no duplicate owner row created).
        await viewModel.saveOwner(
            displayName: "Paul F. Reeks", email: "paul@example.com", role: "CEO",
            organization: "Arivo", domain: "Product", notes: nil
        )
        #expect(viewModel.owner?.id == ownerId)
        #expect(viewModel.owner?.displayName == "Paul F. Reeks")
        #expect(viewModel.owner?.role == "CEO")

        let allPersons = try await database.persons.all()
        #expect(allPersons.filter(\.isOwner).count == 1)
    }

    @Test("confirmPendingFact and rejectPendingFact mutate the fact then refresh pending + counts")
    func confirmAndRejectPendingFact() async throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let person = Person(
            id: "person-ada", displayName: "Ada Lovelace", isOwner: false, createdAt: now, updatedAt: now
        )
        try await database.persons.upsert(person)
        let confirmMe = ProfileFact(
            id: "fact-confirm", personId: person.id, factText: "Learning Swift",
            factKind: .interest, origin: .attributed, confidence: 0.6, sourceCount: 1,
            status: .pending, createdAt: now
        )
        let rejectMe = ProfileFact(
            id: "fact-reject", personId: person.id, factText: "Dislikes coffee",
            factKind: .other, origin: .attributed, confidence: 0.5, sourceCount: 1,
            status: .pending, createdAt: now
        )
        try await database.profileFacts.upsert(confirmMe)
        try await database.profileFacts.upsert(rejectMe)

        let viewModel = PeopleListViewModel(database: database)
        await viewModel.observe()
        #expect(viewModel.pendingFacts.count == 2)
        #expect(viewModel.factCounts[person.id]?.pending == 2)

        await viewModel.confirmPendingFact(confirmMe.id)
        #expect(viewModel.pendingFacts.map(\.fact.id) == [rejectMe.id])
        #expect(viewModel.factCounts[person.id]?.pending == 1)
        #expect(viewModel.factCounts[person.id]?.active == 1)

        await viewModel.rejectPendingFact(rejectMe.id)
        #expect(viewModel.pendingFacts.isEmpty)
        #expect(viewModel.factCounts[person.id]?.pending ?? 0 == 0)

        let confirmed = try await database.profileFacts.find(confirmMe.id)
        #expect(confirmed?.status == .active)
        let rejected = try await database.profileFacts.find(rejectMe.id)
        #expect(rejected?.status == .rejected)
    }
}
