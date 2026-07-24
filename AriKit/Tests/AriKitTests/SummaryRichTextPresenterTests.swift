//
//  SummaryRichTextPresenterTests.swift — blocks → AttributedString presentation
//  (`docs/plans/rich-summary-editor.md` §2.3, §5 tests 8-12).
//
import Testing
@testable import AriKit

@Suite("SummaryRichText presenter")
struct SummaryRichTextPresenterTests {
    @Test("headings stamp their level and a ramp font at every level 1...6")
    func headingsStampLevelAndRampFont() {
        for level in 1 ... 6 {
            let blocks: [MarginaliaMarkdownBlock] = [.heading(level: level, text: "Title")]
            let presented = SummaryRichText.present(blocks)
            guard let run = presented.runs.first else {
                Issue.record("expected at least one run for level \(level)")
                continue
            }
            #expect(run.summaryBlock == .heading(level: level))
            #expect(run.font != nil)
        }
    }

    @Test("paragraph internal hard breaks become U+2028, staying one block attribute")
    func paragraphInternalNewlinesBecomeLineSeparators() {
        let blocks: [MarginaliaMarkdownBlock] = [.paragraph("Line one\nLine two")]
        let presented = SummaryRichText.present(blocks)
        let characters = String(presented.characters)
        #expect(characters.contains("\u{2028}"))
        #expect(!characters.contains("\n"))
        // Every run in this single block carries the SAME summaryBlock kind (one attribute).
        let kinds = Set(presented.runs.map(\.summaryBlock))
        #expect(kinds.count == 1)
        #expect(kinds.first == .paragraph)
    }

    @Test("bullet and numbered items stamp their kind with literal, renumbered markers")
    func bulletAndNumberedItemsStampKindWithLiteralMarkers() {
        let bullets = SummaryRichText.present([.bulletList(["First", "Second"])])
        let bulletText = String(bullets.characters)
        #expect(bulletText == "•\tFirst\n•\tSecond")
        for run in bullets.runs {
            #expect(run.summaryBlock == .bulletItem)
        }

        let numbered = SummaryRichText.present([.numberedList(["Alpha", "Beta"])])
        let numberedText = String(numbered.characters)
        #expect(numberedText == "1.\tAlpha\n2.\tBeta")
        for run in numbered.runs {
            #expect(run.summaryBlock == .numberedItem)
        }
    }

    @Test("bold/italic map to the canonical font set")
    func boldItalicMapToCanonicalFontSet() {
        let blocks: [MarginaliaMarkdownBlock] = [.paragraph("plain **bold** *italic* ***both***")]
        let presented = SummaryRichText.present(blocks)
        // Four distinct fonts expected: plain, bold, italic, bold+italic.
        let fonts = Set(presented.runs.compactMap(\.font))
        #expect(fonts.count == 4)
    }

    @Test("citations remain verbatim, literal, and character-identical")
    func citationsRemainVerbatimLiteralText() {
        let samples = ["Ping [03:09] Amy.", "See @ref(03:09) for detail.", "Cross-meeting @mref(m2@04:10) note."]
        for sample in samples {
            let presented = SummaryRichText.present([.paragraph(sample)])
            #expect(String(presented.characters) == sample)
        }
    }
}
