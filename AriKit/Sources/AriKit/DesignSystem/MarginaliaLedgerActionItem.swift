//
//  MarginaliaLedgerActionItem.swift — tolerant parsing of a series ledger's "Open action items"
//  status marker (F9), so `MarginaliaMarkdownView` can render it as a `MarginaliaBadge` instead
//  of literal `Status: (new)` text.
//
//  The reduce prompt (`SeriesLedgerReducer.buildReducePrompt`) now pins ONE per-item shape going
//  forward, but ledgers written before that prompt tightened still carry MANY shapes the model
//  free-lanced (surveyed directly from stored ledgers) — and every one of them must keep
//  rendering correctly:
//    - a dedicated table `Status` column whose cell is JUST the marker: `(still open)`
//    - inline, bare, unlabeled: `... (dropped).`
//    - inline, bold, unlabeled: `... **(done)**.`
//    - inline, labeled: `... Status: (new). Ref: @mref(...).` / `... status: (new)` (lowercase)
//    - inline, labeled with the LABEL WORD itself bolded: `... — **status**: (new) @mref(...)`
//    - inline, labeled with a bolded marker: `... Status: **(new)**. Ref: ...`
//    - the whole labeled clause bracket-wrapped: `... [Status: (new)] @mref(...)`
//    - a bare marker bracket-wrapped, with or without a markdown link target:
//      `... [(new)]` / `... [(new)](#action-items)`
//
//  This parser recognizes all of them with ONE tolerant pattern (pure, deterministic, no I/O —
//  mirrors `SeriesLedgerCitations`) so old and new ledgers render identically. When no marker is
//  found, it returns `status: nil` and the text UNCHANGED — never infers a status
//  (No-Fake-State).
//
import Foundation

/// The four ledger action-item status values (`SeriesLedgerReducer.buildReducePrompt`'s pinned
/// vocabulary). No fifth value exists; anything else is left as plain text rather than guessed.
public enum MarginaliaLedgerStatus: Sendable, Equatable, CaseIterable {
    case new
    case stillOpen
    case done
    case dropped

    /// The canonical badge title — Title Case of the source vocabulary, never invented text.
    public var label: String {
        switch self {
        case .new: "New"
        case .stillOpen: "Still open"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }

    /// Maps one matched status token (already isolated by `MarginaliaLedgerActionItem`'s regex —
    /// always `new`, some `still...open` spelling, `done`, or `dropped`, case-insensitively) to
    /// its value.
    fileprivate init?(token: Substring) {
        let normalized = token.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "new": self = .new
        case "done": self = .done
        case "dropped": self = .dropped
        default:
            // Every accepted "still open" spelling (extra whitespace, a hyphen) starts with
            // "still" — the regex below never lets anything else reach this branch.
            guard normalized.hasPrefix("still") else { return nil }
            self = .stillOpen
        }
    }
}

/// Pure parsing of a ledger action-item's status marker out of a bullet's full text or a table
/// cell's raw value. No `View`, no I/O — safe to unit test directly (mirrors
/// `SeriesLedgerCitations`'s split between pure parsing and SwiftUI rendering).
public enum MarginaliaLedgerActionItem {
    /// One status word/phrase, case-insensitively: `new`, `still open` (tolerating a hyphen or
    /// extra whitespace between the two words), `done`, `dropped`.
    private static let statusToken = #"(new|still[\s-]*open|done|dropped)"#

    /// ONE pattern tolerant of every observed shape (all wrapper pieces are optional, so it
    /// degrades gracefully from the fully-decorated form down to a bare `(new)`):
    ///  - an optional enclosing `[...]` bracket pair (some models markdown-link-style the marker,
    ///    with or without an actual `(...)` link target after the closing bracket)
    ///  - an optional `status:` label, itself optionally bolded on the word (`**status**:`)
    ///  - an optional `**...**` bold wrap directly around the parenthetical
    ///  - the parenthetical status token itself — REQUIRED
    ///  - an optional immediately-following period (the sentence-ending `.` some models emit)
    ///
    /// Not cached as a static `Regex` property — `Regex` isn't `Sendable`, so a stored static
    /// value trips Swift 6 strict-concurrency's global-mutable-state check (mirrors
    /// `MarginaliaMarkdown`, which recompiles its patterns per call for the same reason).
    private static var pattern: Regex<AnyRegexOutput> {
        // No `\s*` between the closing `)`/`**`/`]` and what follows — every observed bracket
        // form hugs the parenthetical with no space, and a stray consumed trailing space here
        // would eat the ONE separator space before the next word (instead of leaving a tidy
        // double-space for the caller's collapse step to fix).
        makeRegex(
            #"\[?\s*(?:\*{0,2}status\*{0,2}\s*:\s*)?\*{0,2}\(\s*"#
                + statusToken
                + #"\s*\)\*{0,2}\]?(?:\([^)]*\))?\.?"#
        )
    }

    /// Extracts a trailing status marker from one ledger action-item line (a bullet's full text,
    /// or a table cell's raw value), returning the marker-stripped display text plus the parsed
    /// status. A line/cell that IS just the marker (the dedicated table `Status` column) returns
    /// an EMPTY display text — the badge stands alone. Text with NO recognized marker is
    /// returned UNCHANGED with `status: nil` (No-Fake-State: never infers a status).
    public static func extractStatus(from raw: String) -> (text: String, status: MarginaliaLedgerStatus?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (raw, nil) }
        let regex = pattern

        // The whole cell/line is JUST the marker (a table `Status` column) — collapse to "".
        if let match = trimmed.wholeMatch(of: regex), let status = status(from: match) {
            return ("", status)
        }

        // Otherwise the marker is embedded in a longer line — strip just that substring and
        // collapse the resulting double space.
        if let match = trimmed.firstMatch(of: regex), let status = status(from: match) {
            var stripped = trimmed
            stripped.removeSubrange(match.range)
            stripped = stripped
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (stripped, status)
        }

        return (raw, nil)
    }

    // ---------------------------------------------------------------------
    // Regex helpers
    // ---------------------------------------------------------------------

    private static func status(from match: Regex<AnyRegexOutput>.Match) -> MarginaliaLedgerStatus? {
        guard let token = match.output[1].substring else { return nil }
        return MarginaliaLedgerStatus(token: token)
    }

    private static func makeRegex(_ pattern: String) -> Regex<AnyRegexOutput> {
        guard let regex = try? Regex(pattern) else {
            preconditionFailure("MarginaliaLedgerActionItem regex pattern is a compile-time constant and must be valid")
        }
        return regex.ignoresCase()
    }
}
