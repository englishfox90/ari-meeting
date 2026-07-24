//
//  AskAnswerLinesTests.swift — block-structure parsing for assistant answers: bullets/ordinals,
//  headings, blank-line paragraph breaks, marker-vs-emphasis disambiguation, and per-line
//  citation tokenization (the fix for markdown answers collapsing into one run-on paragraph).
//
import Foundation
import Testing
@testable import AriViewModels

@Suite("AskAnswerLayout")
struct AskAnswerLinesTests {
    @Test("single paragraph is one unmarked line")
    func singleParagraph() {
        let lines = AskAnswerLayout.lines("Just a plain answer.")
        #expect(lines.count == 1)
        #expect(lines[0].marker == nil)
        #expect(!lines[0].isHeading)
        #expect(!lines[0].startsParagraph)
        #expect(lines[0].segments == [.text("Just a plain answer.")])
    }

    @Test("dash/star/plus/dot bullets are detected and stripped")
    func bulletMarkers() {
        for prefix in ["- ", "* ", "+ ", "• "] {
            let lines = AskAnswerLayout.lines("\(prefix)item text")
            #expect(lines.count == 1)
            #expect(lines[0].marker == .bullet)
            #expect(lines[0].segments == [.text("item text")])
        }
    }

    @Test("ordinal markers keep the model's own label")
    func ordinalMarkers() {
        let lines = AskAnswerLayout.lines("1. first\n12) twelfth")
        #expect(lines.count == 2)
        #expect(lines[0].marker == .number("1."))
        #expect(lines[0].segments == [.text("first")])
        #expect(lines[1].marker == .number("12)"))
        #expect(lines[1].segments == [.text("twelfth")])
    }

    @Test("**bold** and *italic* at line start are NOT bullets")
    func emphasisIsNotABullet() {
        let bold = AskAnswerLayout.lines("**Key Action Items:** none")
        #expect(bold[0].marker == nil)
        let italic = AskAnswerLayout.lines("*emphasis* only")
        #expect(italic[0].marker == nil)
    }

    @Test("# headings are flagged with hashes stripped")
    func headings() {
        let lines = AskAnswerLayout.lines("## Discussion Topics\nbody line")
        #expect(lines.count == 2)
        #expect(lines[0].isHeading)
        #expect(lines[0].segments == [.text("Discussion Topics")])
        #expect(!lines[1].isHeading)
    }

    @Test("blank lines mark the next line as a paragraph start, never emit a line")
    func paragraphBreaks() {
        let lines = AskAnswerLayout.lines("first\n\nsecond\nthird")
        #expect(lines.count == 3)
        #expect(!lines[0].startsParagraph)
        #expect(lines[1].startsParagraph)
        #expect(!lines[2].startsParagraph)
    }

    @Test("leading blank lines don't flag the first line")
    func leadingBlankLines() {
        let lines = AskAnswerLayout.lines("\n\nonly line")
        #expect(lines.count == 1)
        #expect(!lines[0].startsParagraph)
    }

    @Test("citations tokenize per line — a bulleted line keeps its [S<n>] segment")
    func citationsSurvivePerLine() {
        let lines = AskAnswerLayout.lines("- decided the plan [S2]\n- shipped it [S1][S3]")
        #expect(lines.count == 2)
        #expect(lines[0].segments == [.text("decided the plan "), .citation(index: 2)])
        #expect(lines[1].segments == [
            .text("shipped it "),
            .citation(index: 1),
            .citation(index: 3),
        ])
    }

    @Test("indented list items are treated as list items (flattened)")
    func indentedBullets() {
        let lines = AskAnswerLayout.lines("  - nested item")
        #expect(lines.count == 1)
        #expect(lines[0].marker == .bullet)
        #expect(lines[0].segments == [.text("nested item")])
    }

    @Test("the screenshot shape — bold headings + dash bullets — becomes structured lines")
    func realWorldAnswerShape() {
        let answer = """
        **Discussion Topics:**
        - **Department Reorganization** – reviewing hiring needs
        - **Automoto Call** – scheduled for tomorrow

        **Key Action Items:**
        - Amy to call Automoto tomorrow
        """
        let lines = AskAnswerLayout.lines(answer)
        #expect(lines.count == 5)
        #expect(lines[0].marker == nil)
        #expect(lines[1].marker == .bullet)
        #expect(lines[2].marker == .bullet)
        #expect(lines[3].startsParagraph)
        #expect(lines[4].marker == .bullet)
    }
}
