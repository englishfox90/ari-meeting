//
//  ProfileFactWithPerson.swift — a `ProfileFact` paired with its owning person's display name
//  (plan `docs/plans/people-view-parity.md` §2.1 Slice 1), for the pending-facts review list that
//  spans every person rather than one (← Rust `ProfileFactWithPerson`, `persons/commands.rs`).
//
//  Mirrors `ProfileFactWithProvenance`'s shape/style: a pure composition of already-persisted
//  value types, not a denormalized store — `personDisplayName` is read live at query time.
//
import Foundation

/// A `ProfileFact` composed with the display name of the person it belongs to, without forcing
/// the Store to denormalize (No-Fake-State — the name is joined at read time, never stored).
public struct ProfileFactWithPerson: Codable, Hashable, Sendable {
    public var fact: ProfileFact
    public var personId: PersonID
    public var personDisplayName: String

    public init(fact: ProfileFact, personId: PersonID, personDisplayName: String) {
        self.fact = fact
        self.personId = personId
        self.personDisplayName = personDisplayName
    }
}
