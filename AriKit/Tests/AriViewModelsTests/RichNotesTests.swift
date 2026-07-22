//
//  RichNotesTests.swift — HTML calendar-notes parsing (RichNotes.swift).
//
//  The fixture mirrors the real-world shape that motivated the feature: a Loom HTML fragment
//  (<div>/<b>/<a>/<br> + entities) followed by Google Meet's plain-text tail with bare URLs.
//
import Foundation
import Testing
@testable import AriViewModels

@Suite("RichNotes")
@MainActor
struct RichNotesTests {
    private let loomSample = """
    <div id="loom-description"><b>This meeting will be recorded by Loom.</b><br>Set up <a \
    href="https://www.loom.com/confluence-meeting-notes?workspace=44250898&amp;siteId=b9db">\
    meeting notes</a><br></div>

    Join with Google Meet: https://meet.google.com/whz-ydgh-rug
    Please do not edit this section.
    """

    @Test("HTML detection: tags and entities trip it, plain prose does not")
    func htmlDetection() {
        #expect(RichNotes.looksLikeHTML("<b>bold</b>"))
        #expect(RichNotes.looksLikeHTML("<div id=\"x\">y</div>"))
        #expect(RichNotes.looksLikeHTML("a &amp; b"))
        #expect(!RichNotes.looksLikeHTML("lunch at 12, bring < $20"))
        #expect(!RichNotes.looksLikeHTML("plain notes\nwith lines"))
    }

    @Test("HTML notes: tags stripped, entities decoded, text preserved")
    func htmlStrippedAndDecoded() {
        let result = RichNotes.attributed(from: loomSample)
        let text = String(result.characters)
        #expect(!text.contains("<"))
        #expect(!text.contains("&amp;"))
        #expect(text.contains("This meeting will be recorded by Loom."))
        #expect(text.contains("meeting notes"))
        #expect(text.contains("Please do not edit this section."))
    }

    @Test("anchor href survives as a tappable link on the anchor text")
    func anchorBecomesLink() {
        let result = RichNotes.attributed(from: loomSample)
        let linked = result.runs.compactMap(\.link)
        #expect(linked.contains { $0.absoluteString.hasPrefix("https://www.loom.com/confluence-meeting-notes") })
    }

    @Test("bold tag becomes a strong-emphasis intent, not an explicit font")
    func boldBecomesIntent() {
        let result = RichNotes.attributed(from: loomSample)
        let hasBoldRun = result.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                && String(result.characters[run.range]).contains("recorded by Loom")
        }
        #expect(hasBoldRun)
    }

    @Test("bare URLs in the plain-text tail are linkified")
    func bareURLsLinkified() {
        let result = RichNotes.attributed(from: loomSample)
        let linked = result.runs.compactMap(\.link)
        #expect(linked.contains { $0.absoluteString.contains("meet.google.com/whz-ydgh-rug") })
    }

    @Test("plain-text newlines survive the HTML path as line structure")
    func plainNewlinesSurvive() throws {
        let result = RichNotes.attributed(from: loomSample)
        let text = String(result.characters)
        // "Join with Google Meet" and "Please do not edit" were separate lines in the source
        // and must not be collapsed onto one.
        let joinLine = try #require(text.range(of: "Join with Google Meet"))
        let editLine = try #require(text.range(of: "Please do not edit"))
        #expect(text[joinLine.upperBound ..< editLine.lowerBound].contains("\n"))
    }

    @Test("plain notes pass through with bare URLs linkified and no mangling")
    func plainPassThrough() {
        let result = RichNotes.attributed(from: "Agenda: standup\nDocs: https://example.com/doc")
        let text = String(result.characters)
        #expect(text == "Agenda: standup\nDocs: https://example.com/doc")
        #expect(result.runs.compactMap(\.link).contains { $0.absoluteString.hasPrefix("https://example.com/doc") })
    }

    @Test("empty and whitespace-only notes yield an empty result")
    func emptyNotes() {
        #expect(String(RichNotes.attributed(from: "").characters).isEmpty)
        #expect(String(RichNotes.attributed(from: "  \n ").characters).isEmpty)
    }
}
