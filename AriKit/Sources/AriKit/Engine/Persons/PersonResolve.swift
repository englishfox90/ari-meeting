//
//  PersonResolve.swift — pure email/name matching against a meeting's linked participants
//  (Phase 3.4 Track H §2.2, ← `ari-engine/src/persons/extraction.rs::resolve_person`).
//
//  Case-insensitive; email takes priority over name. No match → `nil` (never guesses — the
//  caller skips the item rather than attributing it to the wrong person).
//
import Foundation

public enum PersonResolve {
    public static func resolvePerson(in participants: [Person], email: String?, name: String?) -> Person? {
        if let email {
            if let found = participants.first(where: { participant in
                guard let candidate = participant.email else { return false }
                return candidate.caseInsensitiveCompare(email) == .orderedSame
            }) {
                return found
            }
        }
        if let name {
            return participants.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
        }
        return nil
    }
}
