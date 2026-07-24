//
//  AskAnswerLines.swift — line/block structure for a RecallEngine-reconciled answer string.
//
//  `AskAnswerTokenizer` splits an answer into citation/timestamp/text segments but knows nothing
//  about lines — and the view's word-flow layout collapses every whitespace run (newlines
//  included) into a uniform gap, which turns a bulleted markdown answer into one run-on
//  paragraph. This parser restores the block structure the model actually emitted: it splits the
//  answer into display lines, detects list markers (`- ` / `* ` / `+ ` / `• ` / `1. ` / `1) `)
//  and `#`-headings, and records blank-line paragraph breaks — then tokenizes each line's content
//  with `AskAnswerTokenizer` so citation/timestamp markers keep working per line.
//
//  Pure and stateless: no re-verification of anything (the engine already reconciled the answer),
//  no invented structure — a line only gets a marker/heading if its own text carries one.
//
import Foundation

/// One display line of an assistant answer, in original top-to-bottom order.
public struct AskAnswerLine: Hashable, Sendable {
    /// A leading list marker, stripped from `segments` and rendered by the view.
    public enum Marker: Hashable, Sendable {
        case bullet
        /// The ordinal's display label exactly as the model wrote it (e.g. `"3."` or `"3)"`).
        case number(String)
    }

    public var marker: Marker?
    /// A `#{1,6} ` markdown heading line (hashes stripped) — the view renders it emphasized.
    public var isHeading: Bool
    /// True when one or more blank lines preceded this line — the view adds paragraph spacing.
    public var startsParagraph: Bool
    public var segments: [AskAnswerSegment]

    public init(
        marker: Marker? = nil,
        isHeading: Bool = false,
        startsParagraph: Bool = false,
        segments: [AskAnswerSegment]
    ) {
        self.marker = marker
        self.isHeading = isHeading
        self.startsParagraph = startsParagraph
        self.segments = segments
    }
}

public enum AskAnswerLayout {
    /// Splits `answer` into ordered display lines. Blank lines never produce a line of their own —
    /// they set `startsParagraph` on the next real line. A line that is only a bare list marker
    /// (e.g. `"-"`) is dropped.
    public static func lines(_ answer: String) -> [AskAnswerLine] {
        var lines: [AskAnswerLine] = []
        var pendingParagraphBreak = false

        for rawLine in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                pendingParagraphBreak = !lines.isEmpty
                continue
            }

            var content = trimmed
            var marker: AskAnswerLine.Marker?
            var isHeading = false

            if let stripped = strippedHeading(content) {
                isHeading = true
                content = stripped
            } else if let (parsedMarker, rest) = strippedListMarker(content) {
                marker = parsedMarker
                content = rest
            }

            let segments = AskAnswerTokenizer.tokenize(content)
            guard !segments.isEmpty else { continue }

            lines.append(AskAnswerLine(
                marker: marker,
                isHeading: isHeading,
                startsParagraph: pendingParagraphBreak,
                segments: segments
            ))
            pendingParagraphBreak = false
        }
        return lines
    }

    /// `#{1,6} ` heading → the text after the hashes, or nil.
    private static func strippedHeading(_ line: String) -> String? {
        var index = line.startIndex
        var hashes = 0
        while index < line.endIndex, line[index] == "#", hashes < 6 {
            hashes += 1
            index = line.index(after: index)
        }
        guard hashes >= 1, index < line.endIndex, line[index].isWhitespace else { return nil }
        let text = line[index...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// `- ` / `* ` / `+ ` / `• ` bullet or `1. ` / `1) ` ordinal → (marker, remaining text), or
    /// nil. Requires whitespace after the marker so `**bold**` / `*italic*` are never mistaken
    /// for bullets.
    private static func strippedListMarker(_ line: String) -> (AskAnswerLine.Marker, String)? {
        if let first = line.first, "-*+•".contains(first) {
            let rest = line.dropFirst()
            guard let next = rest.first, next.isWhitespace else { return nil }
            return (.bullet, rest.trimmingCharacters(in: .whitespaces))
        }

        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber, line.distance(from: line.startIndex, to: index) < 3 {
            index = line.index(after: index)
        }
        guard index > line.startIndex, index < line.endIndex else { return nil }
        let punct = line[index]
        guard punct == "." || punct == ")" else { return nil }
        let afterPunct = line.index(after: index)
        guard afterPunct < line.endIndex, line[afterPunct].isWhitespace else { return nil }
        let label = String(line[line.startIndex ... index])
        return (.number(label), line[afterPunct...].trimmingCharacters(in: .whitespaces))
    }
}
