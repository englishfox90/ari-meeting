//
//  EmailValidation.swift — the one place authored `Person.email` values are validated and
//  normalized before they reach the store.
//
//  Why this exists (2026-07-23 duplicate-Ryan incident): `Person.email` is the natural key
//  the calendar-attendee dedup (`PersonRepository.upsertStubFromAttendee` → `findByEmail`)
//  keys off. When a *name* ("Ryan Chadwick") was accidentally typed into the email field of an
//  already-imported person, dedup could no longer match the real address, so a second stub row
//  was created for the same human. Two guards close that hole at the authored-edit boundary:
//
//  1. **Validate** — a value that isn't a plausible email is rejected, so a display name can
//     never masquerade as the identity key.
//  2. **Normalize** — trim + lowercase, so case/whitespace variants collapse to one key
//     (the store's `UNIQUE` on `email` is case-sensitive BINARY, while `findByEmail` matches
//     case-insensitively; normalizing on write keeps those two from disagreeing).
//
//  Immutability-once-set is enforced by the callers (the identity view models), not here — this
//  type only answers "is this a usable email, and what's its canonical form".
//
import Foundation

public enum EmailValidation {
    /// Trims surrounding whitespace and lowercases. Returns `nil` for a value that is `nil` or
    /// empty after trimming (i.e. "no email"), so callers can treat "cleared" and "never set"
    /// identically.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A deliberately conservative structural check: exactly one `@`, a non-empty local part, and
    /// a domain containing a dot with non-empty labels. Not RFC 5322 — the goal is only to reject
    /// obvious non-emails (names, free text), not to police exotic-but-valid addresses.
    public static func isValid(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: \.isWhitespace) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let (local, domain) = (parts[0], parts[1])
        guard !local.isEmpty, !domain.isEmpty else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }
}
