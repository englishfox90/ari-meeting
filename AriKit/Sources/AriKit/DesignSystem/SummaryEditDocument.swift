//
//  SummaryEditDocument.swift — the segment model for the rich-text summary editor
//  (`docs/plans/rich-summary-editor.md` §2.2).
//
//  Tables are read-only islands, so the document is an alternating list of editable runs
//  and verbatim table slabs, split from the raw source LINES using the same table
//  detection the parser uses (`MarginaliaMarkdown.isTableRow`/`isTableSeparator`) so a
//  table here is exactly the same line-run the parser would see.
//
import Foundation

public struct SummaryEditDocument: Equatable, Sendable {
    /// One piece of the document: an editable, block-stamped run of prose, or a verbatim,
    /// never-rewritten table slab.
    public enum Segment: Equatable, Sendable, Identifiable {
        /// A styled, block-kind-stamped editable run (possibly empty).
        case editable(id: Int, text: AttributedString)
        /// A table slab: the EXACT source lines, joined verbatim with `\n`. Never editable,
        /// never rewritten.
        case table(id: Int, rawMarkdown: String)

        public var id: Int {
            switch self {
            case let .editable(id, _): id
            case let .table(id, _): id
            }
        }
    }

    public var segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    /// Split + present: raw markdown → segments.
    ///
    /// Scans source lines the same way `MarginaliaMarkdown.parse` scans tables (a
    /// `isTableRow` header immediately followed by `isTableSeparator`, then rows while
    /// `isTableRow`), so a table line-run here is byte-identical to what the parser would
    /// treat as one table block. Everything between table runs is joined back into markdown
    /// text and presented as ONE `.editable` segment via `SummaryRichText.present(markdown:)`.
    ///
    /// The result always begins and ends with `.editable` (empty if the source starts/ends
    /// with a table), and there is always exactly one `.editable` segment between any two
    /// `.table` segments (empty when the source had only blank lines there).
    public static func make(from markdown: String) -> SummaryEditDocument {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        // Alternating raw chunks: `.proseLines` (joined back with `\n` before presenting) and
        // `.tableLines` (joined back with `\n` verbatim). Built first so the "always begins/ends
        // editable, exactly one editable between tables" invariant is a property of THIS list
        // rather than something reconstructed after the fact.
        enum RawChunk {
            case prose([String])
            case table([String])
        }

        var chunks: [RawChunk] = []
        var prose: [String] = []
        var index = 0

        func flushProse() {
            chunks.append(.prose(prose))
            prose.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if MarginaliaMarkdown.isTableRow(trimmed), index + 1 < lines.count,
               MarginaliaMarkdown.isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushProse()
                var tableLines = [lines[index], lines[index + 1]]
                index += 2
                while index < lines.count,
                      MarginaliaMarkdown.isTableRow(lines[index].trimmingCharacters(in: .whitespaces)) {
                    tableLines.append(lines[index])
                    index += 1
                }
                chunks.append(.table(tableLines))
                continue
            }

            prose.append(line)
            index += 1
        }
        flushProse()

        // Ensure the chunk list always begins/ends with a (possibly empty) `.prose` chunk, and
        // never has two `.table` chunks adjacent without a `.prose` chunk between them (an empty
        // one if the source had none there).
        if case .table = chunks.first {
            chunks.insert(.prose([]), at: 0)
        }
        if case .table = chunks.last {
            chunks.append(.prose([]))
        }
        var normalized: [RawChunk] = []
        for chunk in chunks {
            if case .table = chunk, case .table = normalized.last {
                normalized.append(.prose([]))
            }
            normalized.append(chunk)
        }
        if normalized.isEmpty {
            normalized = [.prose([])]
        }

        var segments: [Segment] = []
        var nextID = 0
        for chunk in normalized {
            switch chunk {
            case let .prose(proseLines):
                let markdown = proseLines.joined(separator: "\n")
                segments.append(.editable(id: nextID, text: SummaryRichText.present(markdown: markdown)))
            case let .table(tableLines):
                segments.append(.table(id: nextID, rawMarkdown: tableLines.joined(separator: "\n")))
            }
            nextID += 1
        }
        return SummaryEditDocument(segments: segments)
    }

    /// Rejoin + serialize: segments → markdown.
    ///
    /// Editable runs are serialized via `SummaryRichText.serialize`; table slabs are emitted
    /// byte-identical. Segments are joined by exactly one blank line; an empty editable run
    /// contributes nothing beyond that separator. No trailing newline.
    public func serialized() -> String {
        var pieces: [String] = []
        for segment in segments {
            let piece: String = switch segment {
            case let .editable(_, text):
                SummaryRichText.serialize(text)
            case let .table(_, rawMarkdown):
                rawMarkdown
            }
            if !piece.isEmpty {
                pieces.append(piece)
            }
        }
        return pieces.joined(separator: "\n\n")
    }
}
