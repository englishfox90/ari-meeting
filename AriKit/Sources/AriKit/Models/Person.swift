//
//  Person.swift — authored identity, tier 1 (← Rust `Person`, persons/models.rs:8).
//
//  The two-tier identity split (F2): `Person` is the **authored** identity — never collapsed
//  with the **inferred** `ProfileFact` (tier 2). `isOwner` marks the recording owner. `domain`
//  is already present in the Rust row (no Store delta). `createdAt`/`updatedAt` are real
//  instants (`Date`).
//
import Foundation

/// Typed identifier for a `Person` (plan §7.4).
public typealias PersonID = Identifier<Person>

public struct Person: Codable, Hashable, Sendable, Identifiable {
    public var id: PersonID
    public var email: String?
    public var displayName: String
    public var role: String?
    public var organization: String?
    public var domain: String?
    public var notes: String?
    public var isOwner: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: PersonID,
        email: String? = nil,
        displayName: String,
        role: String? = nil,
        organization: String? = nil,
        domain: String? = nil,
        notes: String? = nil,
        isOwner: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.role = role
        self.organization = organization
        self.domain = domain
        self.notes = notes
        self.isOwner = isOwner
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
