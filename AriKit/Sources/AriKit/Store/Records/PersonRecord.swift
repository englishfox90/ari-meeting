//
//  PersonRecord.swift — GRDB record for the `person` table (plan §4.5).
//
//  Store-internal only — `PersonRepository` translates to/from the public
//  `AriKit.Models.Person` value type. `isOwner`'s single-true-row invariant is enforced by
//  `PersonRepository.setOwner(_:)`, not a DB constraint (plan §0.1(4)).
//
import Foundation
import GRDB

struct PersonRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "person"

    var id: String
    var email: String?
    var displayName: String
    var role: String?
    var organization: String?
    var domain: String?
    var notes: String?
    var isOwner: Bool
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}

extension PersonRecord {
    init(_ person: Person) {
        id = person.id.rawValue
        email = person.email
        displayName = person.displayName
        role = person.role
        organization = person.organization
        domain = person.domain
        notes = person.notes
        isOwner = person.isOwner
        createdAt = person.createdAt
        updatedAt = person.updatedAt
        isDeleted = false
        deletedAt = nil
    }

    func asModel() -> Person {
        Person(
            id: PersonID(id),
            email: email,
            displayName: displayName,
            role: role,
            organization: organization,
            domain: domain,
            notes: notes,
            isOwner: isOwner,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
