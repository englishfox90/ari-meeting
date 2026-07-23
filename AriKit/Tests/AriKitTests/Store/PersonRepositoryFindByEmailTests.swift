//
//  PersonRepositoryFindByEmailTests.swift — docs/plans/speaker-retag-and-calendar-candidates.md
//  §5, step 1 (`PersonRepository.findByEmail` public read).
//
import Foundation
import Testing
@testable import AriKit

@Suite("PersonRepository.findByEmail (speaker-retag-and-calendar-candidates §2/step 1)")
struct PersonRepositoryFindByEmailTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePerson(_ id: PersonID, email: String?, name: String = "Nia") -> Person {
        Person(id: id, email: email, displayName: name, isOwner: false, createdAt: instant, updatedAt: instant)
    }

    @Test(
        "findByEmail is case-insensitive and excludes deleted rows, and never writes (mirrors PersonRecord.swift:331-336)"
    )
    func findByEmailIsCaseInsensitiveAndExcludesDeleted() async throws {
        let db = try AppDatabase.makeInMemory()
        let matchId: PersonID = "person-match"
        try await db.persons.upsert(makePerson(matchId, email: "Nia@Example.com"))
        let deletedId: PersonID = "person-deleted"
        try await db.persons.upsert(makePerson(deletedId, email: "gone@example.com", name: "Gone"))
        try await db.persons.softDelete(deletedId, at: instant)

        let before = try await db.persons.all(includingDeleted: true).count

        let found = try await db.persons.findByEmail("nia@example.com")
        #expect(found?.id == matchId)

        let deletedLookup = try await db.persons.findByEmail("gone@example.com")
        #expect(deletedLookup == nil)

        let unmatched = try await db.persons.findByEmail("nobody@example.com")
        #expect(unmatched == nil)

        let after = try await db.persons.all(includingDeleted: true).count
        #expect(after == before, "findByEmail must never write")
    }
}
