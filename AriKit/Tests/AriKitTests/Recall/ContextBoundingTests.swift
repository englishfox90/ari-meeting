//
//  ContextBoundingTests.swift — plan §6 Slice 1 test 4.
//
//  1:1 port of the Rust `meeting_recall_context_keeps_the_start_and_conclusion` (shell.rs:543) and
//  `recall_context_includes_real_date_summary_and_transcript_once_per_meeting` (shell.rs:568).
//
import Testing
@testable import AriKit

@Suite struct ContextBoundingTests {
    @Test func meetingRecallContextKeepsStartAndConclusion() {
        let longSegment = "Henry opened the meeting. "
            + String(repeating: "middle ", count: 2_000)
            + "The action items are keep it simple, test real inputs, and trace claims to evidence."
        let sources = Recall.buildMeetingSources([
            TranscriptSearchResult(
                id: "meeting-1",
                title: "AI meeting",
                matchContext: longSegment,
                timestamp: "00:00",
                meetingDate: "2026-07-13",
                summary: nil
            )
        ])

        #expect(sources.count == 1)
        #expect(sources[0].matchContext.hasPrefix("Henry opened the meeting."))
        #expect(sources[0].matchContext.contains("The action items are keep it simple"))
        #expect(sources[0].matchContext.unicodeScalars.count <= RecallBounds.maxSourceChars + 3)
    }

    @Test func contextIncludesRealDateSummaryAndTranscriptOncePerMeeting() {
        // JSON with a literal backslash-n; serde/JSONSerialization decode it to a real newline.
        let rawSummary = "{\"markdown\":\"## Decisions\\nKeep recall local.\"}"
        #expect(Recall.summaryMarkdown(rawSummary) == "## Decisions\nKeep recall local.")
        #expect(Recall.summaryMarkdown("Legacy plain-text summary") == "Legacy plain-text summary")

        let sources = [
            RecallSource(
                meetingId: "meeting-1",
                title: "AI review",
                matchContext: "Henry opened the review.",
                timestamp: "00:05",
                meetingDate: "2026-07-13T10:00:00Z",
                summary: Recall.summaryMarkdown(rawSummary)
            ),
            RecallSource(
                meetingId: "meeting-1",
                title: "AI review",
                matchContext: "Trent confirmed the decision.",
                timestamp: "00:30",
                meetingDate: "2026-07-13T10:00:00Z",
                summary: Recall.summaryMarkdown(rawSummary)
            )
        ]

        let context = Recall.buildContext(sources)
        #expect(context.contains("meeting date 2026-07-13T10:00:00Z"))
        #expect(context.contains("Saved summary:\n## Decisions"))
        #expect(context.contains("Transcript excerpt:\nHenry opened"))
        #expect(context.components(separatedBy: "Saved summary:").count - 1 == 1)
    }

    /// Locks in the Unicode-scalar counting decision (review LOW-2). Rust `str::chars()` iterates
    /// Unicode scalars, so `boundedMiddleExcerpt` must budget in scalars, NOT graphemes. `👍🏽` is a
    /// single `Character` but two scalars (U+1F44D U+1F3FD); a refactor to `Character` counting
    /// would silently pass every ASCII test while breaking parity with Rust — this input catches it.
    @Test func middleExcerptBudgetsInScalarsNotGraphemes() {
        let grapheme = "👍🏽" // 1 Character, 2 Unicode scalars
        let text = String(repeating: grapheme, count: 10)
        #expect(text.count == 10) // graphemes
        #expect(text.unicodeScalars.count == 20) // scalars

        // max = 12: over the 20-scalar length (→ truncates), but under the 10-grapheme count
        // (grapheme counting would wrongly return the text unchanged).
        let excerpt = Recall.boundedMiddleExcerpt(text, max: 12)
        #expect(excerpt.contains("…"))
        #expect(excerpt.unicodeScalars.count <= 12 + 3) // head + "\n…\n" + tail, counted in scalars
        #expect(excerpt != text)

        // Within budget (by scalars): returned unchanged.
        #expect(Recall.boundedMiddleExcerpt(text, max: 20) == text)
    }
}
