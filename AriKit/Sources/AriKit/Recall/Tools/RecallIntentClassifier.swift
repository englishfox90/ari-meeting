//
//  RecallIntentClassifier.swift — the v1 heuristic intent classifier for Ask Meetings' structured
//  tools (plan §4.1/§4.2, `docs/plans/ask-meetings-tools-and-cards.md`).
//
//  A pure, synchronous, `Sendable` enum-namespace of static functions — no I/O, no async, no LLM
//  call — recognizing a small, FIXED set of entity-shaped question patterns ("last meeting with
//  <name>", "meetings with <name>", "did I meet with <name>", "meetings in the <series> series").
//
//  Deliberately narrow (plan §4.1): a FALSE NEGATIVE (fails to recognize an entity-shaped question)
//  safely falls through to the existing hybrid-RAG path unchanged — no regression. A FALSE POSITIVE
//  (misclassifies an open-ended question) is guarded downstream by `RecallTools`' own ambiguity
//  discipline — an extracted name/title that doesn't resolve to EXACTLY ONE real row is also a safe
//  fall-through (No-Fake-State), never a fabricated card. This classifier therefore only needs to
//  decide "does this look entity-shaped," not "is this extraction certainly correct."
//
import Foundation

/// Enum-namespace (never instantiated) of pure pattern-matching functions over a question string.
public enum RecallIntentClassifier {
    /// The recognized entity-lookup shapes. Associated values are the raw (lowercased, trimmed)
    /// candidate substring to resolve — `RecallTools` does the actual, ambiguity-safe resolution.
    public enum Intent: Sendable, Equatable {
        /// "last meeting with X" / "meetings with X" / "did I meet with X".
        case personMeetings(nameQuery: String)
        /// "meetings in the X series".
        case seriesMeetings(titleQuery: String)
    }

    /// Recognizes trigger phrases for a person-meetings lookup. Order matters only in that longer,
    /// more specific triggers are tried first so a shorter trigger can't swallow part of a longer
    /// one's match range.
    private static let personTriggers = ["meetings with ", "meeting with ", "meet with "]

    /// Trailing clauses that qualify rather than name the person/series — trimmed off the
    /// extracted candidate so "meetings with Sarah about the budget" extracts "Sarah", not
    /// "Sarah about the budget".
    private static let trailingQualifiers = [" about ", " regarding ", " concerning ", "?", "."]

    public static func classify(_ question: String) -> Intent? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        if let title = seriesTitle(in: lower) {
            return .seriesMeetings(titleQuery: title)
        }
        if let name = personName(in: lower) {
            return .personMeetings(nameQuery: name)
        }
        return nil
    }

    // MARK: - "meetings in the <series> series"

    private static func seriesTitle(in lower: String) -> String? {
        guard lower.contains("meeting") else { return nil }
        // Anchor on " series" first, then take the CLOSEST preceding "in the " — a sentence can
        // contain an earlier, unrelated "in the" (e.g. "... in the last meeting in the X series"),
        // and the title is always the phrase immediately between the last "in the " and " series".
        guard let seriesRange = lower.range(of: " series") else { return nil }
        guard let inTheRange = lastRange(of: "in the ", in: lower, before: seriesRange.lowerBound)
        else { return nil }
        let title = String(lower[inTheRange.upperBound ..< seriesRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// The last occurrence of `pattern` fully contained before `index`, or `nil` if none.
    private static func lastRange(
        of pattern: String,
        in text: String,
        before index: String.Index
    ) -> Range<String.Index>? {
        var searchRange = text.startIndex ..< index
        var result: Range<String.Index>?
        while let found = text.range(of: pattern, range: searchRange) {
            result = found
            guard found.upperBound < index else { break }
            searchRange = found.upperBound ..< index
        }
        return result
    }

    // MARK: - "meeting(s)/meet with <name>"

    private static func personName(in lower: String) -> String? {
        for trigger in personTriggers {
            guard let range = lower.range(of: trigger) else { continue }
            var rest = String(lower[range.upperBound...])
            for qualifier in trailingQualifiers {
                if let stopRange = rest.range(of: qualifier) {
                    rest = String(rest[rest.startIndex ..< stopRange.lowerBound])
                }
            }
            let name = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }
        return nil
    }
}
