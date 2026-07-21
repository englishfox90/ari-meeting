//
//  PersonResolveTests.swift — Phase 3.4 Track H §2.6 (← `resolve_person`, `extraction.rs:246`).
//
import Foundation
import Testing
@testable import AriKit

@Suite("PersonResolve — email/name matching against a participant roster")
struct PersonResolveTests {
    private func person(id: String, email: String?, name: String) -> Person {
        Person(
            id: PersonID(id),
            email: email,
            displayName: name,
            isOwner: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("Matches by email, case-insensitively")
    func matchesByEmailCaseInsensitive() {
        let sarah = person(id: "p1", email: "sarah@example.com", name: "Sarah")
        let resolved = PersonResolve.resolvePerson(in: [sarah], email: "SARAH@EXAMPLE.COM", name: nil)
        #expect(resolved?.id == sarah.id)
    }

    @Test("Falls back to name matching, case-insensitively, when email doesn't match")
    func fallsBackToNameCaseInsensitive() {
        let sarah = person(id: "p1", email: "sarah@example.com", name: "Sarah")
        let resolved = PersonResolve.resolvePerson(in: [sarah], email: "nobody@example.com", name: "sarah")
        #expect(resolved?.id == sarah.id)
    }

    @Test("Email takes priority over name")
    func emailTakesPriorityOverName() {
        let sarah = person(id: "p1", email: "sarah@example.com", name: "Sarah")
        let bob = person(id: "p2", email: "bob@example.com", name: "Bob")
        // Name says "Bob" but email says "sarah@example.com" — email wins.
        let resolved = PersonResolve.resolvePerson(in: [sarah, bob], email: "sarah@example.com", name: "Bob")
        #expect(resolved?.id == sarah.id)
    }

    @Test("No email and no name match returns nil — never guesses")
    func noMatchReturnsNil() {
        let sarah = person(id: "p1", email: "sarah@example.com", name: "Sarah")
        let resolved = PersonResolve.resolvePerson(in: [sarah], email: "nobody@example.com", name: "Nobody")
        #expect(resolved == nil)
    }

    @Test("Both email and name nil returns nil")
    func bothNilReturnsNil() {
        let sarah = person(id: "p1", email: "sarah@example.com", name: "Sarah")
        let resolved = PersonResolve.resolvePerson(in: [sarah], email: nil, name: nil)
        #expect(resolved == nil)
    }

    @Test("Empty participant list returns nil")
    func emptyParticipantsReturnsNil() {
        let resolved = PersonResolve.resolvePerson(in: [], email: "sarah@example.com", name: "Sarah")
        #expect(resolved == nil)
    }
}
