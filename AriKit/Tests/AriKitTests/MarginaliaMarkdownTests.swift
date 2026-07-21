//
//  MarginaliaMarkdownTests.swift — the block-structure parser (headings, lists, tables,
//  paragraphs) and the citation-marker display normalization.
//
import Testing
@testable import AriKit

@Suite("MarginaliaMarkdown parser")
struct MarginaliaMarkdownTests {

    @Test("headings capture level and text; `#foo` is not a heading")
    func headings() {
        #expect(MarginaliaMarkdown.parse("# Summary") == [.heading(level: 1, text: "Summary")])
        #expect(MarginaliaMarkdown.parse("### Key Decisions") == [.heading(level: 3, text: "Key Decisions")])
        // No space after the hashes → a paragraph, not a heading.
        #expect(MarginaliaMarkdown.parse("#nothashed") == [.paragraph("#nothashed")])
    }

    @Test("consecutive bullet lines group into one list")
    func bulletList() {
        let markdown = """
        - First item
        - Second item
        * Third item
        """
        #expect(MarginaliaMarkdown.parse(markdown) == [
            .bulletList(["First item", "Second item", "Third item"])
        ])
    }

    @Test("numbered lines group and drop their source numbering")
    func numberedList() {
        let markdown = """
        1. Alpha
        2) Beta
        """
        #expect(MarginaliaMarkdown.parse(markdown) == [.numberedList(["Alpha", "Beta"])])
    }

    @Test("a GitHub table parses into header + rows, framing pipes dropped")
    func table() {
        let markdown = """
        | Owner | Task | Due |
        | --- | --- | --- |
        | Amy | Register state | N/A |
        | Taylor | Send projections | N/A |
        """
        #expect(MarginaliaMarkdown.parse(markdown) == [
            .table(
                header: ["Owner", "Task", "Due"],
                rows: [["Amy", "Register state", "N/A"], ["Taylor", "Send projections", "N/A"]]
            )
        ])
    }

    @Test("pipe lines without a separator row are NOT a table")
    func pipesWithoutSeparator() {
        let markdown = "| just | text |"
        #expect(MarginaliaMarkdown.parse(markdown) == [.paragraph("| just | text |")])
    }

    @Test("soft-wrapped lines join into one paragraph; blank lines split blocks")
    func paragraphs() {
        let markdown = """
        Line one
        line two

        Second paragraph
        """
        #expect(MarginaliaMarkdown.parse(markdown) == [
            .paragraph("Line one line two"),
            .paragraph("Second paragraph")
        ])
    }

    @Test("a realistic summary keeps its structure")
    func mixedDocument() {
        let markdown = """
        # Summary
        The meeting covered planning.

        ## Key Decisions
        - Follow up with James
        - Register the state
        """
        #expect(MarginaliaMarkdown.parse(markdown) == [
            .heading(level: 1, text: "Summary"),
            .paragraph("The meeting covered planning."),
            .heading(level: 2, text: "Key Decisions"),
            .bulletList(["Follow up with James", "Register the state"])
        ])
    }

    @Test("displayText rewrites @ref(MM:SS) to [MM:SS] and leaves [MM:SS] intact")
    func displayText() {
        #expect(MarginaliaMarkdown.displayText("done @ref(24:06) today") == "done [24:06] today")
        #expect(MarginaliaMarkdown.displayText("see [3:59]") == "see [3:59]")
        #expect(MarginaliaMarkdown.displayText("at @ref(1:02:03)") == "at [1:02:03]")
    }

    @Test("displayText rewrites the series @mref(m<N>@TS) to a plain [TS], dropping the member index")
    func displayTextMref() {
        #expect(MarginaliaMarkdown.displayText("fix punctuality @mref(m1@06:31).") == "fix punctuality [06:31].")
        #expect(MarginaliaMarkdown.displayText("later @mref(m2@1:02:03)") == "later [1:02:03]")
    }

    @Test("hasCitation is true for any marker form, false for plain prose")
    func hasCitation() {
        #expect(MarginaliaMarkdown.hasCitation("see [3:59]"))
        #expect(MarginaliaMarkdown.hasCitation("done @ref(24:06)"))
        #expect(MarginaliaMarkdown.hasCitation("done @mref(m1@06:31)"))
        #expect(!MarginaliaMarkdown.hasCitation("no markers here"))
    }

    @Test("inlineSpans splits an audio marker into text + citation + text with a canonical label")
    func inlineSpansAudio() {
        #expect(MarginaliaMarkdown.inlineSpans("done [3:09] today") == [
            .text("done "),
            .citation(.audio(seconds: 189, label: "03:09")),
            .text(" today")
        ])
        // @ref parses to the same audio citation shape.
        #expect(MarginaliaMarkdown.inlineSpans("at @ref(24:06)") == [
            .text("at "),
            .citation(.audio(seconds: 1446, label: "24:06"))
        ])
    }

    @Test("inlineSpans carries the member index for a series @mref citation")
    func inlineSpansMref() {
        #expect(MarginaliaMarkdown.inlineSpans("fix it @mref(m2@06:31).") == [
            .text("fix it "),
            .citation(.meeting(memberIndex: 2, seconds: 391, label: "06:31")),
            .text(".")
        ])
    }

    @Test("inlineSpans with no markers yields a single text span")
    func inlineSpansPlain() {
        #expect(MarginaliaMarkdown.inlineSpans("just prose") == [.text("just prose")])
    }

    @Test("a >59-minute meeting's MMM:SS marker parses (engine emits 120:45, not an hour form)")
    func inlineSpansLongMeeting() {
        // 120 min 45 s = 7245 s; label promotes to H:MM:SS for an unambiguous chip.
        #expect(MarginaliaMarkdown.hasCitation("late @mref(m1@120:45)"))
        #expect(MarginaliaMarkdown.inlineSpans("late @mref(m1@120:45)") == [
            .text("late "),
            .citation(.meeting(memberIndex: 1, seconds: 7245, label: "2:00:45"))
        ])
        #expect(MarginaliaMarkdown.displayText("late @mref(m1@120:45)") == "late [120:45]")
    }
}
