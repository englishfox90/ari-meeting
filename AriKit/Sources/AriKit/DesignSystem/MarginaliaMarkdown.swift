//
//  MarginaliaMarkdown.swift — a block-level markdown renderer themed to the Marginalia ramp.
//
//  `MarkdownText` (app target) renders a whole document as one inline `AttributedString`, which
//  flattens headings, lists, and tables into undifferentiated body text — the reason a summary
//  reads "bare bones". This renderer parses the document into structural BLOCKS first (headings,
//  paragraphs, bullet/numbered lists, GitHub tables) and renders each with the correct Marginalia
//  type style, so a summary keeps its hierarchy.
//
//  Two halves, deliberately split so the structural logic is testable without a `View`:
//   • `MarginaliaMarkdown` — a pure, Sendable parser (`parse(_:)`) + display helpers.
//   • `MarginaliaMarkdownView` — the SwiftUI renderer that maps blocks onto the type ramp.
//
//  Inline emphasis (`**bold**` / `*italic*`) is handled per-block via `AttributedString`'s
//  inline-only markdown parsing. Full markdown fidelity (nested lists, block quotes, fenced
//  code) is a known, accepted gap (plan risks) — the summary content this renders in practice is
//  headings + bullets + one action-items table.
//
import SwiftUI

/// One structural block parsed from a markdown document. Plain data (no `View`) so the parser
/// can be unit-tested directly (`AriKitTests/MarginaliaMarkdownTests`).
public enum MarginaliaMarkdownBlock: Equatable, Sendable {
    /// A heading. `level` is the count of leading `#` (clamped 1...6).
    case heading(level: Int, text: String)
    /// A run of body text (soft-wrapped source lines joined with a space).
    case paragraph(String)
    /// An unordered list; each element is one item's raw text.
    case bulletList([String])
    /// An ordered list; each element is one item's raw text (the source numbering is dropped —
    /// the renderer re-numbers from 1).
    case numberedList([String])
    /// A GitHub-flavored table: a header row plus zero or more body rows, each already split
    /// into trimmed cells.
    case table(header: [String], rows: [[String]])
}

/// A citation marker found inside inline text. Two flavors of the same "jump to a moment" idea:
///  • `audio` — a moment in THIS document's own recording (`[MM:SS]` / `@ref(MM:SS)`), seeked in
///    place by the local audio player.
///  • `meeting` — a cross-document moment in a series ledger (`@mref(m<index>@<TS>)`), carrying the
///    1-based member index so the caller can open that member meeting at the timestamp. This is
///    what makes a series ledger a *connected* record — every claim points back at its source.
public enum InlineCitation: Equatable, Sendable {
    case audio(seconds: Double, label: String)
    case meeting(memberIndex: Int, seconds: Double, label: String)
}

/// One piece of an inline line: literal text (which may still carry `**emphasis**`) or a citation.
public enum InlineSpan: Equatable, Sendable {
    case text(String)
    case citation(InlineCitation)
}

/// Pure markdown-structure parsing + display normalization. No `View`, no I/O — safe to unit test.
public enum MarginaliaMarkdown {
    /// Parses a markdown document into structural blocks. Best-effort and forgiving: anything it
    /// doesn't recognize becomes paragraph text, never an error.
    public static func parse(_ markdown: String) -> [MarginaliaMarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MarginaliaMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // Preserve hard line breaks: the LLM writes one logical line per source line (e.g. a
            // "**Meeting Metadata**" / "**Date:** …" / "**Participants:**" stack) without blank
            // separators, and joining those with a space collapsed them onto one run-on line. The
            // inline renderer parses with `.inlineOnlyPreservingWhitespace`, so a `\n` here survives
            // as a real line break. (Genuine soft-wrapped prose — rare from these models — would now
            // hard-break, which reads fine for meeting notes.)
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Table: a `|`-delimited header row immediately followed by a `|---|` separator row.
            if isTableRow(trimmed), index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2 // consume header + separator
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isTableRow(rowLine) else { break }
                    rows.append(tableCells(rowLine))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let heading = headingBlock(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if let item = bulletItem(trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count, let next = bulletItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if let item = numberedItem(trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count, let next = numberedItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// Normalizes citation markers for display: `@ref(MM:SS)` → `[MM:SS]` and the series ledger's
    /// `@mref(m<index>@MM:SS)` → `[MM:SS]`, so every marker form reads identically inline. Left as
    /// `[MM:SS]` (not stripped) — the bracket is the visible citation affordance; the tappable seek
    /// (or cross-meeting open) is layered on separately by the renderer. This is the plain-text
    /// fallback rendering: it deliberately drops the member index, which is only needed when the
    /// marker becomes interactive (see `inlineSpans`).
    public static func displayText(_ text: String) -> String {
        var result = text
        if let mref = try? Regex("@mref\\(m\\d+@(\\d{1,4}:[0-5]\\d(?::[0-5]\\d)?)\\)") {
            result = result.replacing(mref) { match in
                "[\(match.output[1].substring.map(String.init) ?? "")]"
            }
        }
        if let ref = try? Regex("@ref\\((\\d{1,4}:[0-5]\\d(?::[0-5]\\d)?)\\)") {
            result = result.replacing(ref) { match in
                "[\(match.output[1].substring.map(String.init) ?? "")]"
            }
        }
        return result
    }

    /// The three inline citation forms, as one alternation. Ordered mref-first so `@mref(...)` is
    /// never mis-parsed as an `@ref(...)` sitting inside it. The leading component is `\d{1,4}` to
    /// mirror the engine's `TS_BODY` (`ledger_citations.rs`): a >59-minute meeting emits `MMM:SS`
    /// (e.g. `120:45`) without rolling into an hour component, so `\d{1,2}` would drop those.
    ///  • g1..g4 — mref: index, then H-or-M : M-or-S (: S)?
    ///  • g5..g7 — `@ref(...)`: H-or-M : M-or-S (: S)?
    ///  • g8..g10 — `[...]`: H-or-M : M-or-S (: S)?
    private static let citationPattern =
        "@mref\\(m(\\d+)@(\\d{1,4}):([0-5]\\d)(?::([0-5]\\d))?\\)" +
        "|@ref\\((\\d{1,4}):([0-5]\\d)(?::([0-5]\\d))?\\)" +
        "|\\[(\\d{1,4}):([0-5]\\d)(?::([0-5]\\d))?\\]"

    /// True when `raw` contains at least one citation marker of any form.
    public static func hasCitation(_ raw: String) -> Bool {
        guard let regex = try? Regex(citationPattern) else { return false }
        return raw.firstMatch(of: regex) != nil
    }

    /// Splits `raw` into interleaved literal-text and citation spans, preserving order. Text
    /// between markers keeps its `**emphasis**` for the renderer to interpret; citation spans
    /// carry parsed seconds + a canonical label (and, for a series `@mref`, the member index). No
    /// markers → a single `.text(raw)` span.
    public static func inlineSpans(_ raw: String) -> [InlineSpan] {
        guard let regex = try? Regex(citationPattern) else { return [.text(raw)] }
        var spans: [InlineSpan] = []
        var cursor = raw.startIndex
        for match in raw.matches(of: regex) {
            let range = match.range
            if cursor < range.lowerBound {
                spans.append(.text(String(raw[cursor ..< range.lowerBound])))
            }
            if let citation = citation(from: match) {
                spans.append(.citation(citation))
            } else {
                // Unparseable numbers — keep the literal marker text rather than invent a moment.
                spans.append(.text(String(raw[range])))
            }
            cursor = range.upperBound
        }
        if cursor < raw.endIndex {
            spans.append(.text(String(raw[cursor...])))
        }
        return spans.isEmpty ? [.text(raw)] : spans
    }

    /// Maps a `citationPattern` match to a typed `InlineCitation` by which branch fired.
    private static func citation(from match: Regex<AnyRegexOutput>.Match) -> InlineCitation? {
        let out = match.output
        // Branch 1 — @mref(m<index>@...)
        if let index = out[1].substring.flatMap({ Int($0) }) {
            guard let seconds = seconds(out[2], out[3], out[4]) else { return nil }
            return .meeting(memberIndex: index, seconds: seconds, label: label(out[2], out[3], out[4]))
        }
        // Branch 2 — @ref(...)
        if out[5].substring != nil {
            guard let seconds = seconds(out[5], out[6], out[7]) else { return nil }
            return .audio(seconds: seconds, label: label(out[5], out[6], out[7]))
        }
        // Branch 3 — [...]
        if out[8].substring != nil {
            guard let seconds = seconds(out[8], out[9], out[10]) else { return nil }
            return .audio(seconds: seconds, label: label(out[8], out[9], out[10]))
        }
        return nil
    }

    /// Seconds from three timestamp groups: `a:b` = MM:SS, `a:b:c` = H:MM:SS. `nil` if a/b don't
    /// parse as integers.
    private static func seconds(
        _ a: AnyRegexOutput.Element, _ b: AnyRegexOutput.Element, _ c: AnyRegexOutput.Element
    ) -> Double? {
        guard let first = a.substring.flatMap({ Int($0) }),
              let second = b.substring.flatMap({ Int($0) }) else { return nil }
        if let third = c.substring.flatMap({ Int($0) }) {
            return Double(first * 3600 + second * 60 + third)
        }
        return Double(first * 60 + second)
    }

    /// The canonical `MM:SS` / `H:MM:SS` label for three timestamp groups, from the parsed
    /// seconds (so `[3:9]` normalizes to `03:09` — one consistent chip label everywhere).
    private static func label(
        _ a: AnyRegexOutput.Element, _ b: AnyRegexOutput.Element, _ c: AnyRegexOutput.Element
    ) -> String {
        guard let seconds = seconds(a, b, c) else { return "" }
        return MarginaliaTimecode.label(seconds)
    }

    // MARK: - Line classification

    private static func headingBlock(_ line: String) -> MarginaliaMarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil } // `#foo` is not a heading; `# foo` is
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard let separator = afterDigits.first, separator == "." || separator == ")" else { return nil }
        let afterSeparator = afterDigits.dropFirst()
        guard afterSeparator.first == " " else { return nil }
        return afterSeparator.trimmingCharacters(in: .whitespaces)
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.dropFirst().contains("|")
    }

    /// A separator row is all `-`, `:`, `|`, and spaces, and contains at least one `-`.
    private static func isTableSeparator(_ line: String) -> Bool {
        guard isTableRow(line), line.contains("-") else { return false }
        return line.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // A leading/trailing `|` yields an empty first/last cell — drop those framing empties.
        if cells.first == "" {
            cells.removeFirst()
        }
        if cells.last == "" {
            cells.removeLast()
        }
        return cells
    }
}
