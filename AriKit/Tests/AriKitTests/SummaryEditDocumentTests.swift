//
//  SummaryEditDocumentTests.swift — the alternating editable-run / verbatim-table-slab
//  segment model (`docs/plans/rich-summary-editor.md` §2.2, §5 tests 1-7).
//
import Testing
@testable import AriKit

@Suite("SummaryEditDocument segmenter")
struct SummaryEditDocumentTests {
    private func editableText(_ document: SummaryEditDocument, at index: Int) -> String {
        guard case let .editable(_, text) = document.segments[index] else {
            Issue.record("expected an editable segment at \(index)")
            return ""
        }
        return String(text.characters)
    }

    @Test("no tables → a single editable segment")
    func splitNoTablesYieldsSingleEditableSegment() {
        let markdown = "# Heading\n\nSome body text."
        let document = SummaryEditDocument.make(from: markdown)
        #expect(document.segments.count == 1)
        guard case .editable = document.segments[0] else {
            Issue.record("expected a single editable segment")
            return
        }
    }

    @Test("a table-only document is bracketed by empty editables")
    func splitTableOnlyDocumentBracketsWithEmptyEditables() {
        let markdown = """
        | Owner | Task |
        | --- | --- |
        | Amy | Ship it |
        """
        let document = SummaryEditDocument.make(from: markdown)
        #expect(document.segments.count == 3)
        guard case let .editable(_, leading) = document.segments[0],
              case .table = document.segments[1],
              case let .editable(_, trailing) = document.segments[2] else {
            Issue.record("expected editable/table/editable")
            return
        }
        #expect(String(leading.characters).isEmpty)
        #expect(String(trailing.characters).isEmpty)
    }

    @Test("blank-line-separated tables keep an empty editable between them")
    func splitBlankLineSeparatedTablesKeepEmptyEditableBetween() {
        let markdown = """
        | A | B |
        | --- | --- |
        | 1 | 2 |

        | C | D |
        | --- | --- |
        | 3 | 4 |
        """
        let document = SummaryEditDocument.make(from: markdown)
        // editable, table, editable, table, editable
        #expect(document.segments.count == 5)
        guard case .editable = document.segments[0],
              case .table = document.segments[1],
              case let .editable(_, middle) = document.segments[2],
              case .table = document.segments[3],
              case .editable = document.segments[4] else {
            Issue.record("expected editable/table/editable/table/editable")
            return
        }
        #expect(String(middle.characters).isEmpty)
    }

    @Test("contiguous table lines with no blank line are one slab")
    func splitContiguousTableLinesAreOneSlab() {
        let markdown = """
        | A | B |
        | --- | --- |
        | 1 | 2 |
        | 3 | 4 |
        """
        let document = SummaryEditDocument.make(from: markdown)
        #expect(document.segments.count == 3) // editable, ONE table, editable
        guard case let .table(_, raw) = document.segments[1] else {
            Issue.record("expected a single table slab")
            return
        }
        #expect(raw.components(separatedBy: "\n").count == 4)
    }

    @Test("a table slab is byte-identical, including alignment colons and ragged rows")
    func tableSlabIsByteIdentical() {
        let markdown = """
        Notes before.

        | Owner | Task   | Due |
        | :--- | ---: | :---: |
        | Amy   | Register state | N/A   |
        | Taylor | Send projections |

        Notes after.
        """
        let document = SummaryEditDocument.make(from: markdown)
        let tableSlabs: [String] = document.segments.compactMap {
            if case let .table(_, raw) = $0 {
                return raw
            }
            return nil
        }
        guard let raw = tableSlabs.first, tableSlabs.count == 1 else {
            Issue.record("expected exactly one table segment")
            return
        }
        let expectedLines = [
            "| Owner | Task   | Due |",
            "| :--- | ---: | :---: |",
            "| Amy   | Register state | N/A   |",
            "| Taylor | Send projections |"
        ]
        #expect(raw == expectedLines.joined(separator: "\n"))
        #expect(document.serialized().contains(raw))
    }

    @Test("serialized() joins segments with a single blank line; empty editables contribute nothing")
    func serializedJoinsSegmentsWithSingleBlankLine() {
        let markdown = """
        Intro paragraph.

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let document = SummaryEditDocument.make(from: markdown)
        let serialized = document.serialized()
        #expect(serialized == "Intro paragraph.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
    }

    @Test("an empty body makes one empty editable and serializes to empty")
    func emptyBodyMakesOneEmptyEditableAndSerializesEmpty() {
        let document = SummaryEditDocument.make(from: "")
        #expect(document.segments.count == 1)
        #expect(editableText(document, at: 0).isEmpty)
        #expect(document.serialized().isEmpty)
    }
}
