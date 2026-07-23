//
//  SummaryCitations.swift — deterministic timestamp-citation post-processing for the SUMMARY
//  pipeline (plan §2.5, ← summary/citations.rs `apply_citations`).
//
//  ⚠️ NOT the recall citations. `Recall/Citations/Citations.swift` already ports
//  `recall/citations.rs` (`verifySourceCitations`/`parseTimestampLabel`/`filterRefTimestamps`) —
//  Recall Slice 1, reused as-is by the recall Orchestrator. THIS file is the distinct
//  `summary/citations.rs` port: it verifies/snaps/drops `@ref(MM:SS)` tokens the summarizer emits
//  against the real transcript, plus conservatively back-fills missing citations onto table `Ref`
//  columns and Decision/Action bullets. It is invoked by the summary pipeline
//  (`SummaryGenerator`), never by recall.
//
//  Pure, deterministic, panic-free by construction (Swift has no `catch_unwind` equivalent to
//  guard here — there is nothing in this file that can trap). Per No-Fake-State, it never invents
//  a timestamp: every `@ref(...)` it produces or leaves behind traces to a real transcript line,
//  and anything it can't establish with confidence is dropped/omitted rather than guessed.
//
import Foundation

public enum SummaryCitations {
    /// Stats from a single `applyCitations` pass, surfaced for logging only (← `CitationStats`).
    public struct CitationStats: Sendable, Equatable {
        public var verified: Int = 0
        public var snapped: Int = 0
        public var dropped: Int = 0
        public var backfilled: Int = 0

        public init(verified: Int = 0, snapped: Int = 0, dropped: Int = 0, backfilled: Int = 0) {
            self.verified = verified
            self.snapped = snapped
            self.dropped = dropped
            self.backfilled = backfilled
        }
    }

    /// How close (in seconds) a model-emitted `@ref(...)` may be to a real transcript marker
    /// before it's considered a near-miss worth snapping rather than a hallucination worth
    /// dropping.
    private static let snapToleranceSecs = 8

    /// Minimum lexical-overlap coverage required before back-filling a missing citation.
    private static let backfillMinScore = 0.5

    /// Absolute floor on shared, non-stopword tokens required for a back-fill match.
    private static let minTokenOverlap = 3

    // ---------------------------------------------------------------------
    // Public entry point
    // ---------------------------------------------------------------------

    /// Deterministically verifies, snaps, and conservatively back-fills `@ref(...)` timestamp
    /// citations in `summaryMarkdown` against the real `[MM:SS]`-marked lines in
    /// `sourceTranscript` (← `apply_citations`).
    public static func applyCitations(
        _ summaryMarkdown: String,
        sourceTranscript: String
    ) -> (String, CitationStats) {
        let segments = parseSegments(sourceTranscript)
        // Pass 0: promote bare `(MM:SS)` parentheticals — which the small on-device model frequently
        // emits instead of the instructed `@ref(MM:SS)` — into real `@ref(...)` tokens, but ONLY
        // when they snap to a real transcript marker. Non-matching timestamps are left as plain text
        // (No-Fake-State: never fabricate a badge, never delete the model's prose). This makes the
        // reference badges robust to the model's inconsistent citation formatting.
        let promoted = promoteParenTimestamps(summaryMarkdown, segments: segments)
        let (afterRefs, verified, snapped, dropped) = processRefTokens(promoted, segments: segments)
        let (afterBackfill, backfilled) = backfillMissing(afterRefs, segments: segments)
        return (
            afterBackfill,
            CitationStats(verified: verified, snapped: snapped, dropped: dropped, backfilled: backfilled)
        )
    }

    // ---------------------------------------------------------------------
    // Transcript parsing
    // ---------------------------------------------------------------------

    private struct Segment {
        let seconds: Int
        let text: String
    }

    /// Matches a leading `[MM:SS]` or `[H:MM:SS]` transcript marker (← `SEGMENT_MARKER_RE`).
    private static let segmentMarkerRegex: NSRegularExpression = makeRegex(
        #"^\[(\d{1,4}):([0-5]\d)(?::([0-5]\d))?\]\s*(.*)$"#
    )

    private static func parseSegments(_ sourceTranscript: String) -> [Segment] {
        var segments: [Segment] = []
        for line in sourceTranscript.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let match = segmentMarkerRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: ns.length)
            ) else {
                continue
            }
            let seconds = secondsFromMatch(match, ns: ns, a: 1, b: 2, c: 3)
            let textRange = match.range(at: 4)
            let text = textRange.location != NSNotFound
                ? ns.substring(with: textRange).trimmingCharacters(in: .whitespaces)
                : ""
            segments.append(Segment(seconds: seconds, text: text))
        }
        segments.sort { $0.seconds < $1.seconds }
        return segments
    }

    /// Shared seconds computation for both transcript markers and `@ref(...)` tokens
    /// (← `seconds_from_marker_caps`).
    private static func secondsFromMatch(_ match: NSTextCheckingResult, ns: NSString, a: Int, b: Int, c: Int) -> Int {
        func group(_ index: Int) -> Int {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let value = Int(ns.substring(with: range)) else {
                return 0
            }
            return value
        }
        if match.range(at: c).location != NSNotFound {
            return group(a) * 3600 + group(b) * 60 + group(c)
        }
        return group(a) * 60 + group(b)
    }

    /// Renders seconds back into the canonical citation label (← `format_hms`).
    private static func formatHMS(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    // ---------------------------------------------------------------------
    // Pass 1: verify / snap / drop existing @ref(...) tokens
    // ---------------------------------------------------------------------

    /// Captures an optional single leading space/tab plus the `@ref(...)` body (← `REF_TOKEN_RE`).
    private static let refTokenRegex: NSRegularExpression = makeRegex(
        #"[ \t]?@ref\((\d{1,4}):([0-5]\d)(?::([0-5]\d))?\)"#
    )

    /// Nearest segment to `targetSeconds`, as `(segmentSeconds, absDiff)`. Ties favor the earlier
    /// segment (← `nearest_segment`).
    private static func nearestSegment(_ segments: [Segment], _ targetSeconds: Int) -> (Int, Int)? {
        var best: (Int, Int)?
        for segment in segments {
            let diff = abs(segment.seconds - targetSeconds)
            if best == nil || diff < best!.1 {
                best = (segment.seconds, diff)
            }
        }
        return best
    }

    // ---------------------------------------------------------------------
    // Pass 0: promote bare `(MM:SS)` parentheticals into `@ref(...)` (when real)
    // ---------------------------------------------------------------------

    /// A bare `(MM:SS)` / `(H:MM:SS)` parenthetical that is NOT already the body of an `@ref(...)`
    /// (the negative lookbehind rejects the `(` in `@ref(`). Brackets `[MM:SS]` are already a
    /// recognized badge form, so only the paren form needs promoting.
    private static let parenTimestampRegex: NSRegularExpression = makeRegex(
        #"(?<!ref)\((\d{1,4}):([0-5]\d)(?::([0-5]\d))?\)"#
    )

    /// Rewrites each bare `(MM:SS)` that snaps to a real transcript marker (within
    /// `snapToleranceSecs`) into a canonical `@ref(MM:SS)`; leaves everything else untouched.
    private static func promoteParenTimestamps(_ summaryMarkdown: String, segments: [Segment]) -> String {
        guard !segments.isEmpty else { return summaryMarkdown }
        let ns = summaryMarkdown as NSString
        let matches = parenTimestampRegex.matches(in: summaryMarkdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return summaryMarkdown }

        var result = ""
        var lastEnd = 0
        for match in matches {
            let matchRange = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))

            let targetSeconds = secondsFromMatch(match, ns: ns, a: 1, b: 2, c: 3)
            if case let .some((_, diff)) = nearestSegment(segments, targetSeconds), diff <= snapToleranceSecs {
                // Real (or near-real) timestamp → change only the delimiter form, preserving the
                // model's own time. Pass 1 then does the real verify/snap accounting (an exact hit
                // counts as verified; a near-miss as snapped), so promotion never distorts stats.
                result += "@ref(\(formatHMS(targetSeconds)))"
            } else {
                // Not a real transcript moment — keep the model's literal text; never fabricate a badge.
                result += ns.substring(with: matchRange)
            }
            lastEnd = matchRange.location + matchRange.length
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return result
    }

    private static func processRefTokens(
        _ summaryMarkdown: String,
        segments: [Segment]
    ) -> (String, Int, Int, Int) {
        let ns = summaryMarkdown as NSString
        let matches = refTokenRegex.matches(in: summaryMarkdown, range: NSRange(location: 0, length: ns.length))

        var verified = 0
        var snapped = 0
        var dropped = 0
        var result = ""
        var lastEnd = 0

        for match in matches {
            let matchRange = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))

            let matched = ns.substring(with: matchRange)
            let leadingWs = (matched.first == " " || matched.first == "\t") ? String(matched.first!) : ""
            let targetSeconds = secondsFromMatch(match, ns: ns, a: 1, b: 2, c: 3)

            switch nearestSegment(segments, targetSeconds) {
            case .some((_, 0)):
                verified += 1
                // Keep the model's own formatting verbatim on an exact match.
                result += matched
            case let .some((segSeconds, diff)) where diff <= snapToleranceSecs:
                snapped += 1
                result += "\(leadingWs)@ref(\(formatHMS(segSeconds)))"
            default:
                dropped += 1
                // Dropped entirely: append nothing.
            }

            lastEnd = matchRange.location + matchRange.length
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))

        return (result, verified, snapped, dropped)
    }

    // ---------------------------------------------------------------------
    // Pass 2: conservative back-fill (tables' Ref column + Decision/Action bullets)
    // ---------------------------------------------------------------------

    private static let stopwords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "or", "is", "are", "was", "be", "for", "on", "in", "it",
        "that", "this", "we", "i", "you", "he", "she", "they", "will", "with", "at", "as", "so",
        "but", "if", "do", "does"
    ]

    /// Lowercases, strips punctuation, tokenizes on whitespace, and drops stopwords + short tokens
    /// (← `content_tokens`).
    private static func contentTokens(_ text: String) -> Set<String> {
        var mapped = ""
        mapped.reserveCapacity(text.count)
        for scalar in text.lowercased().unicodeScalars {
            mapped.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return Set(
            mapped.split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 && !stopwords.contains($0) }
        )
    }

    /// Finds the best-scoring 1-2 adjacent-segment window matching `query` (← `best_match`).
    private static func bestMatch(_ query: String, _ segments: [Segment]) -> (Int, Double)? {
        let queryTokens = contentTokens(query)
        guard !queryTokens.isEmpty else {
            return nil
        }

        struct Candidate {
            let score: Double
            let windowSize: Int
            let seconds: Int
            let overlap: Int
        }

        var candidates: [Candidate] = []
        for (index, segment) in segments.enumerated() {
            let segTokens = contentTokens(segment.text)

            let overlap1 = queryTokens.intersection(segTokens).count
            let score1 = Double(overlap1) / Double(queryTokens.count)
            candidates.append(Candidate(score: score1, windowSize: 1, seconds: segment.seconds, overlap: overlap1))

            if index + 1 < segments.count {
                let next = segments[index + 1]
                let mergedTokens = segTokens.union(contentTokens(next.text))
                let overlap2 = queryTokens.intersection(mergedTokens).count
                let score2 = Double(overlap2) / Double(queryTokens.count)
                candidates.append(Candidate(score: score2, windowSize: 2, seconds: segment.seconds, overlap: overlap2))
            }
        }

        /// Prefer higher score; tie-break narrower window, then earlier segment (← the
        /// `total_cmp().then_with(...).then_with(...)` chain feeding `max_by`).
        func isBetter(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.score != b.score {
                return a.score > b.score
            }
            if a.windowSize != b.windowSize {
                return a.windowSize < b.windowSize
            }
            return a.seconds < b.seconds
        }

        var best: Candidate?
        for candidate in candidates where candidate.score >= backfillMinScore && candidate.overlap >= minTokenOverlap {
            if best == nil || isBetter(candidate, best!) {
                best = candidate
            }
        }

        return best.map { ($0.seconds, $0.score) }
    }

    private static func isHeading(_ line: String) -> String? {
        let trimmed = String(line.drop(while: { $0.isWhitespace }))
        guard trimmed.hasPrefix("#") else {
            return nil
        }
        return String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
    }

    private static func headingWantsBackfill(_ headingText: String) -> Bool {
        let lower = headingText.lowercased()
        return lower.contains("decision") || lower.contains("action")
    }

    private static let bulletRegex: NSRegularExpression = makeRegex(#"^(\s*[-*+]\s+)(.*)$"#)

    private static func splitTableCells(_ line: String) -> [String] {
        var inner = line.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("|") {
            inner.removeFirst()
        }
        if inner.hasSuffix("|") {
            inner.removeLast()
        }
        return inner.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let cells = splitTableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func isTableRow(_ line: String) -> Bool {
        String(line.drop(while: { $0.isWhitespace })).hasPrefix("|")
    }

    private static func cleanHeaderCell(_ cell: String) -> String {
        cell.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func refCellIsEmpty(_ cell: String) -> Bool {
        let stripped = cell.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty || ["none", "-", "—", "n/a"].contains(stripped.lowercased())
    }

    private static func rebuildTableRow(_ cells: [String]) -> String {
        "| \(cells.joined(separator: " | ")) |"
    }

    private static func backfillMissing(_ markdown: String, segments: [Segment]) -> (String, Int) {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var backfilled = 0
        var headingWantsRefs = false

        var i = 0
        while i < lines.count {
            let line = lines[i]

            if let headingText = isHeading(line) {
                headingWantsRefs = headingWantsBackfill(headingText)
                out.append(line)
                i += 1
                continue
            }

            // Table detection: header row immediately followed by a separator row.
            if isTableRow(line), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {
                let headerCells = splitTableCells(line)
                let refCol = headerCells.firstIndex { cleanHeaderCell($0) == "ref" }

                out.append(line)
                out.append(lines[i + 1])
                i += 2

                if let refCol {
                    while i < lines.count, isTableRow(lines[i]) {
                        var cells = splitTableCells(lines[i])
                        if refCol < cells.count, refCellIsEmpty(cells[refCol]) {
                            let content = cells.enumerated()
                                .filter { $0.offset != refCol }
                                .map(\.element)
                                .joined(separator: " ")
                            if let (seconds, _) = bestMatch(content, segments) {
                                cells[refCol] = "@ref(\(formatHMS(seconds)))"
                                backfilled += 1
                            }
                            out.append(rebuildTableRow(cells))
                        } else {
                            out.append(lines[i])
                        }
                        i += 1
                    }
                } else {
                    // No Ref column in this table; copy body rows unmodified.
                    while i < lines.count, isTableRow(lines[i]) {
                        out.append(lines[i])
                        i += 1
                    }
                }
                continue
            }

            // Decision/Action bullets missing a citation.
            if headingWantsRefs, !line.contains("@ref(") {
                let ns = line as NSString
                if let match = bulletRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let prefix = ns.substring(with: match.range(at: 1))
                    let body = ns.substring(with: match.range(at: 2))
                    if let (seconds, _) = bestMatch(body, segments) {
                        out.append("\(prefix)\(body) @ref(\(formatHMS(seconds)))")
                        backfilled += 1
                        i += 1
                        continue
                    }
                }
            }

            out.append(line)
            i += 1
        }

        return (out.joined(separator: "\n"), backfilled)
    }

    // ---------------------------------------------------------------------
    // Regex helper
    // ---------------------------------------------------------------------

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("SummaryCitations regex pattern is a compile-time constant and must be valid")
        }
        return regex
    }
}
