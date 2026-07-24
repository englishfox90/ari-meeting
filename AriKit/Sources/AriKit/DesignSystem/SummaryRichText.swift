//
//  SummaryRichText.swift — presenter + serializer for the rich-text summary editor
//  (`docs/plans/rich-summary-editor.md` §2.3).
//
//  `present` turns parsed `MarginaliaMarkdownBlock`s into one styled `AttributedString`
//  whose paragraphs carry `\.summaryBlock` (structure) and canonical fonts (bold/italic
//  identity); `serialize` reverses that, reading `\.summaryBlock` for structure and font
//  IDENTITY (never fonts for structure) to rebuild the closed Marginalia markdown grammar.
//
//  Everything here is pure, synchronous, value-type transformation — no I/O, no shared
//  mutable state, safe to call from any isolation context.
//
import Foundation
import SwiftUI

public enum SummaryRichText {
    /// blocks → one styled `AttributedString`. Every paragraph is stamped with
    /// `\.summaryBlock`; fonts/inks mirror the read view's ramp; citation markers pass
    /// through as literal, untransformed text.
    public static func present(_ blocks: [MarginaliaMarkdownBlock]) -> AttributedString {
        var result = AttributedString()
        var isFirst = true

        func appendBlock(_ kind: SummaryBlockKind, rawContent: String) {
            if !isFirst {
                result += AttributedString("\n")
            }
            isFirst = false
            guard !rawContent.isEmpty else { return }
            // Internal hard breaks (the parser's soft-wrap-stack joiner, `\n`) become U+2028
            // LINE SEPARATOR so the whole stack stays ONE editor paragraph / one attribute run;
            // a real editor Enter — plain `\n` between blocks — is what makes a new block.
            let lineSeparated = rawContent.replacingOccurrences(of: "\n", with: "\u{2028}")
            var block = inlineAttributed(lineSeparated, kind: kind)
            block.summaryBlock = kind
            block.foregroundColor = inkColor(for: kind)
            result += block
        }

        // Tracks whether the previous block was a list, and of which kind — so two SIBLING
        // lists of the SAME kind separated by a blank line in the source get a real block
        // boundary between them (an empty separator paragraph). Without it, their items would
        // present as one contiguous run of same-kind paragraphs and `serialize` would re-emit
        // them adjacent, which re-parses as ONE merged list — breaking the block-stable
        // round-trip invariant (test 20). Different-kind adjacent lists don't merge (the
        // parser's per-kind scan stops), so no separator is needed there.
        var previousListKind: SummaryBlockKind?
        for block in blocks {
            switch block {
            case let .heading(level, text):
                appendBlock(.heading(level: level), rawContent: text)
                previousListKind = nil
            case let .paragraph(text):
                appendBlock(.paragraph, rawContent: text)
                previousListKind = nil
            case let .bulletList(items):
                if previousListKind == .bulletItem {
                    appendBlock(.paragraph, rawContent: "") // list-break boundary
                }
                for item in items {
                    appendBlock(.bulletItem, rawContent: "•\t" + item)
                }
                previousListKind = .bulletItem
            case let .numberedList(items):
                if previousListKind == .numberedItem {
                    appendBlock(.paragraph, rawContent: "") // list-break boundary
                }
                for (offset, item) in items.enumerated() {
                    appendBlock(.numberedItem, rawContent: "\(offset + 1).\t" + item)
                }
                previousListKind = .numberedItem
            case .table:
                // Tables never reach the presenter in practice — `SummaryEditDocument` carves
                // them into verbatim slabs before any prose chunk is handed to `present`. Skip
                // rather than crash if one ever does (defensive, not a supported path).
                continue
            }
        }
        return result
    }

    /// Convenience: parse + present one editable run's source.
    public static func present(markdown: String) -> AttributedString {
        present(MarginaliaMarkdown.parse(markdown))
    }

    /// `AttributedString` → markdown for the closed grammar. Reads `\.summaryBlock` for
    /// structure; reads font identity ONLY to recover bold/italic. Never drops characters
    /// (an empty paragraph serializes to nothing but never eats adjacent content).
    public static func serialize(_ text: AttributedString) -> String {
        guard !text.characters.isEmpty else { return "" }

        // Split into paragraph substrings at literal `\n` — the same boundary
        // `runBoundaries: .paragraph` uses to coalesce `\.summaryBlock`, and exactly what
        // `present(_:)` joins blocks with.
        var paragraphs: [AttributedSubstring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text.characters[index] == "\n" {
                paragraphs.append(text[start ..< index])
                index = text.index(afterCharacter: index)
                start = index
            } else {
                index = text.index(afterCharacter: index)
            }
        }
        paragraphs.append(text[start ..< text.endIndex])

        var pieces: [(kind: SummaryBlockKind, text: String)] = []
        var numberedCounter = 0
        for paragraph in paragraphs {
            let kind = paragraph.runs.first?.summaryBlock ?? .paragraph
            numberedCounter = kind == .numberedItem ? numberedCounter + 1 : 0
            pieces.append((kind, serializeParagraph(paragraph, kind: kind, numberedIndex: numberedCounter)))
        }
        return join(pieces)
    }

    // MARK: - Presentation helpers

    /// Parses `raw` for inline `**bold**`/`*italic*`/`***both***` emphasis and maps each run
    /// to the canonical font for `kind` + that emphasis — the ONLY bold/italic representation
    /// this document uses.
    ///
    /// Deliberately a dedicated regex scan for exactly the closed grammar's three emphasis
    /// forms, NOT `AttributedString(markdown:)` (which the read view uses): Foundation's full
    /// CommonMark inline parser also recognizes code spans, links, and images, and can drop
    /// characters outside our grammar (a fenced-code backtick pair reads as a code span and
    /// disappears). That would violate "never drop characters" for unrecognized constructs
    /// (test 22) — this scanner only ever touches `*` delimiters, so citations, backticks,
    /// brackets, and anything else pass through as pure literal text. Visually identical to
    /// the read view for legitimate bold/italic (same font mapping), safer for everything else.
    private static func inlineAttributed(_ raw: String, kind: SummaryBlockKind) -> AttributedString {
        guard !raw.isEmpty else { return AttributedString() }
        guard let regex = try? Regex(#"\*\*\*([^*]+)\*\*\*|\*\*([^*]+)\*\*|\*([^*]+)\*"#) else {
            var plain = AttributedString(raw)
            plain.font = SummaryFontVariant.base(for: kind)
            return plain
        }

        var result = AttributedString()
        func appendPlain(_ substring: Substring) {
            guard !substring.isEmpty else { return }
            var piece = AttributedString(String(substring))
            piece.font = SummaryFontVariant.base(for: kind)
            result += piece
        }

        var cursor = raw.startIndex
        for match in raw.matches(of: regex) {
            let range = match.range
            if cursor < range.lowerBound {
                appendPlain(raw[cursor ..< range.lowerBound])
            }
            let output = match.output
            if let boldItalic = output[1].substring {
                var piece = AttributedString(String(boldItalic))
                piece.font = SummaryFontVariant.boldItalic(for: kind)
                result += piece
            } else if let bold = output[2].substring {
                var piece = AttributedString(String(bold))
                piece.font = SummaryFontVariant.bold(for: kind)
                result += piece
            } else if let italic = output[3].substring {
                var piece = AttributedString(String(italic))
                piece.font = SummaryFontVariant.italic(for: kind)
                result += piece
            }
            cursor = range.upperBound
        }
        appendPlain(raw[cursor...])
        return result
    }

    private static func inkColor(for kind: SummaryBlockKind) -> Color {
        switch kind {
        case .heading: MarginaliaColors.light.inkHeading
        case .paragraph, .bulletItem, .numberedItem: MarginaliaColors.light.inkBody
        }
    }

    // MARK: - Serialization helpers

    /// Built per call (not a cached static) — `Regex` isn't `Sendable`, and this is a pure,
    /// synchronous function callable from any isolation context; recompiling a small literal
    /// pattern is not a hot path here.
    private static func bulletMarkerRegex() -> Regex<Substring>? {
        try? Regex(#"^(?:[•\-*][ \t]|\t)"#)
    }

    private static func numberedMarkerRegex() -> Regex<Substring>? {
        try? Regex(#"^(?:\d+[.)][ \t])"#)
    }

    /// Strips AT MOST ONE leading marker token from a list-item paragraph — either the
    /// presenter's own visible marker (`"•\t"` / `"1.\t"`) or a stray marker-shaped prefix the
    /// user typed; whatever's left (including a second literal marker) stays as content.
    private static func stripMarker(_ paragraph: AttributedSubstring, kind: SummaryBlockKind) -> AttributedSubstring {
        guard kind == .bulletItem || kind == .numberedItem else { return paragraph }
        let raw = String(paragraph.characters)
        guard let regex = kind == .bulletItem ? bulletMarkerRegex() : numberedMarkerRegex() else { return paragraph }
        guard let match = raw.firstMatch(of: regex) else { return paragraph }
        let dropCount = raw.distance(from: raw.startIndex, to: match.range.upperBound)
        let newStart = paragraph.characters.index(paragraph.startIndex, offsetBy: dropCount)
        return paragraph[newStart...]
    }

    /// Serializes one paragraph's content (after marker-stripping) to markdown: line
    /// separators back to `\n`, emphasis runs back to `**`/`*`/`***`, then the structural
    /// prefix for `kind`. Empty content serializes to nothing (blank-line shaping only).
    private static func serializeParagraph(
        _ paragraph: AttributedSubstring, kind: SummaryBlockKind, numberedIndex: Int
    ) -> String {
        let stripped = stripMarker(paragraph, kind: kind)
        let emphasisMarkdown = emphasisSerialized(stripped, kind: kind)
            .replacingOccurrences(of: "\u{2028}", with: "\n")
        guard !emphasisMarkdown.isEmpty else { return "" }

        switch kind {
        case let .heading(level):
            let clampedLevel = min(max(level, 1), 6)
            return String(repeating: "#", count: clampedLevel) + " " + emphasisMarkdown
        case .paragraph:
            return emphasisMarkdown
        case .bulletItem:
            return "- " + emphasisMarkdown
        case .numberedItem:
            return "\(numberedIndex). " + emphasisMarkdown
        }
    }

    /// Walks the (already marker-stripped) paragraph's runs, wrapping each in `**`/`*`/`***`
    /// per its font's match against the canonical set for `kind`. Adjacent same-style runs
    /// are already coalesced by `AttributedString` (equal attributes merge), so `**a****b**`
    /// never appears.
    private static func emphasisSerialized(_ substring: AttributedSubstring, kind: SummaryBlockKind) -> String {
        var result = ""
        for run in substring.runs {
            let piece = String(substring[run.range].characters)
            guard !piece.isEmpty else { continue }
            let font = run.font
            if font == SummaryFontVariant.boldItalic(for: kind) {
                result += "***\(piece)***"
            } else if font == SummaryFontVariant.bold(for: kind) {
                result += "**\(piece)**"
            } else if font == SummaryFontVariant.italic(for: kind) {
                result += "*\(piece)*"
            } else {
                result += piece
            }
        }
        return result
    }

    /// Joins serialized paragraphs into one document: consecutive SAME-kind list items join
    /// with a single `\n` (no blank line); everything else gets a blank line between it and
    /// its neighbor. An empty piece contributes no text but acts as a BOUNDARY: it forces a
    /// blank line between the real neighbors on either side, so two same-kind list blocks that
    /// `present` separated with an empty paragraph stay two lists (not merged) on reparse.
    private static func join(_ pieces: [(kind: SummaryBlockKind, text: String)]) -> String {
        var result = ""
        var previousKind: SummaryBlockKind?
        var boundarySincePrevious = false
        for (kind, text) in pieces {
            if text.isEmpty {
                boundarySincePrevious = true
                continue
            }
            if result.isEmpty {
                result = text
            } else if isListKind(kind), kind == previousKind, !boundarySincePrevious {
                result += "\n" + text
            } else {
                result += "\n\n" + text
            }
            previousKind = kind
            boundarySincePrevious = false
        }
        return result
    }

    private static func isListKind(_ kind: SummaryBlockKind) -> Bool {
        kind == .bulletItem || kind == .numberedItem
    }
}

/// The closed canonical font set the serializer compares runs against, derived from a
/// paragraph's `SummaryBlockKind`: heading level ≤ 2 → `.title2` ramp, level ≥ 3 →
/// `.headline`; every other kind → `.body` (mirrors `MarginaliaMarkdownView`'s mapping).
///
/// Module-internal (not file-private) so `MarginaliaSummaryFormattingDefinition`'s
/// `SummaryFontConstraint` coerces every editor run to these EXACT `Font` values — the same
/// ones `serialize` compares against. Sharing the one source is what makes the constraint's
/// output identity-canonical: a run the constraint normalizes to `bold(for:)` is byte-for-byte
/// the value the serializer recognizes as `**…**` (plan §2.4, R1). Never fork this mapping.
enum SummaryFontVariant {
    static func base(for kind: SummaryBlockKind) -> Font {
        switch kind {
        case let .heading(level):
            level <= 2 ? MarginaliaTextStyle.title2.font : MarginaliaTextStyle.headline.font
        case .paragraph, .bulletItem, .numberedItem:
            MarginaliaTextStyle.body.font
        }
    }

    static func bold(for kind: SummaryBlockKind) -> Font {
        base(for: kind).bold()
    }

    static func italic(for kind: SummaryBlockKind) -> Font {
        base(for: kind).italic()
    }

    static func boldItalic(for kind: SummaryBlockKind) -> Font {
        base(for: kind).bold().italic()
    }
}
