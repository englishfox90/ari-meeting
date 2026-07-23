//
//  SeriesLedgerCitations.swift — meeting-attributed ledger citations (F9), ported verbatim from
//  `ari-engine/src/meeting_series/ledger_citations.rs`.
//
//  The series ledger is produced by folding each member meeting's summary — which carries
//  verified `@ref(MM:SS)` tokens — through an LLM reduce. In the ledger a bare `@ref(04:21)` is
//  ambiguous: which meeting? This module makes citations meeting-attributed so the series page
//  can render clickable badges that deep-link to the right meeting at the right offset.
//
//  Two deterministic, pure passes (no I/O, no LLM):
//
//  1. `qualifyRefs` — BEFORE the reduce, rewrite each source summary's `@ref(<TS>)` (and the
//     legacy `[MM:SS]` bracket form) into `@mref(m<N>@<TS>)`, where `<N>` is the 1-based index of
//     that meeting in the series' chronological member ordering (exactly
//     `SeriesRepository.orderedMeetingIds` order). The LLM then carries these verbatim.
//  2. `validateQualifiedRefs` — AFTER the reduce, drop any `@mref` whose `<N>` is out of range
//     (LLM mangling/hallucination guard), degrading it to the plain `<TS>` text so the time is
//     still shown but never as a dead badge. This is the No-Fake-State guard.
//
//  The `@mref(...)` marker is deliberately DISTINCT from the summary `@ref(...)` marker
//  (`SummaryCitations.swift`) so summary citation code never touches it, and vice versa:
//    - summary:  `@ref(04:21)`
//    - ledger:   `@mref(m2@04:21)`   (m2 = 2nd meeting of the series, at 04:21)
//
import Foundation

public enum SeriesLedgerCitations {
    /// A timestamp body: `M:SS` / `MM:SS` / `H:MM:SS`. The first group is intentionally
    /// `[0-9]{1,4}` (not `[0-9]{1,2}`) to mirror the summary `@ref(...)` token — a >59-minute
    /// meeting can emit markers like `75:23` rather than rolling into an hour component. The last
    /// groups (minutes/seconds) are constrained to `00`-`59`.
    ///
    /// L3: digit classes are the explicit ASCII `[0-9]`, not `\d` — `NSRegularExpression`'s `\d`
    /// matches any Unicode decimal digit by default, whereas the Rust incumbent's `regex` crate
    /// `\d` is ASCII-only unless the `u` flag is set. `[0-9]` matches that Rust behavior exactly.
    private static let tsBody = #"[0-9]{1,4}:[0-5][0-9](?::[0-5][0-9])?"#

    /// Matches a summary `@ref(<TS>)` token, capturing the timestamp body.
    private static let refTokenRegex = makeRegex("@ref\\((\(tsBody))\\)")

    /// Matches the legacy bracket citation form `[<TS>]`, capturing the timestamp body.
    private static let bracketTokenRegex = makeRegex("\\[(\(tsBody))\\]")

    /// Matches a qualified ledger citation `@mref(m<N>@<TS>)`, capturing `N` and the `<TS>` body.
    private static let mrefTokenRegex = makeRegex("@mref\\(m([0-9]+)@(\(tsBody))\\)")

    /// Rewrite every `@ref(<TS>)` and legacy `[<TS>]` citation in `summaryMarkdown` into a
    /// meeting-attributed `@mref(m<N>@<TS>)`, with `N = memberIndex`. All other text is left
    /// byte-for-byte unchanged. Pure: no I/O, no LLM.
    ///
    /// Call this on EACH member's summary markdown just before it is folded into the reduce
    /// prompt, so the qualified marker survives the LLM pass and can be validated afterward.
    public static func qualifyRefs(_ summaryMarkdown: String, memberIndex: Int) -> String {
        // Pass 1: @ref(TS) → @mref(mN@TS)
        let afterRef = replace(refTokenRegex, in: summaryMarkdown) { groups in
            "@mref(m\(memberIndex)@\(groups[1]))"
        }

        // Pass 2: legacy [TS] → @mref(mN@TS). Runs on the pass-1 output; the two forms are
        // disjoint (one requires `@ref(...)`, the other literal `[...]`) so order is irrelevant.
        return replace(bracketTokenRegex, in: afterRef) { groups in
            "@mref(m\(memberIndex)@\(groups[1]))"
        }
    }

    /// Drop any `@mref(m<N>@<TS>)` whose `N` is not in `1...memberCount`, replacing it with the
    /// plain `<TS>` text (so the moment is still readable, just not a dead badge). In-range
    /// markers are kept verbatim. Pure: no I/O, no LLM.
    ///
    /// This is the No-Fake-State guard against the LLM inventing or corrupting a meeting index
    /// during the reduce. `memberCount` is the total number of members in the series (the valid
    /// range of `N`).
    public static func validateQualifiedRefs(_ ledgerMarkdown: String, memberCount: Int) -> String {
        replace(mrefTokenRegex, in: ledgerMarkdown) { groups in
            let n = Int(groups[1]) ?? 0
            if n >= 1, n <= memberCount {
                // Keep the marker exactly as the model emitted it.
                return "@mref(m\(groups[1])@\(groups[2]))"
            }
            // Out of range → degrade to plain time text (never a dead badge).
            return groups[2]
        }
    }

    // ---------------------------------------------------------------------
    // Regex helpers
    // ---------------------------------------------------------------------

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("SeriesLedgerCitations regex pattern is a compile-time constant and must be valid")
        }
        return regex
    }

    /// Replaces every match of `regex` in `text` using `transform`, which receives the matched
    /// groups by index (`groups[0]` = the whole match, `groups[1...]` = capture groups). All
    /// non-matched text is preserved verbatim.
    private static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        transform: ([String]) -> String
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matches {
            let matchRange = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))

            var groups: [String] = []
            for index in 0 ..< match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location != NSNotFound ? ns.substring(with: range) : "")
            }
            result += transform(groups)

            lastEnd = matchRange.location + matchRange.length
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return result
    }
}
