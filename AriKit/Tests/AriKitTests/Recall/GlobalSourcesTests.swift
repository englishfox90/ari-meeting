//
//  GlobalSourcesTests.swift — plan §6 Slice 1 test 5.
//
//  1:1 port of the Rust `global_recall_returns_one_source_per_meeting_with_bounded_excerpts` case
//  (shell.rs:607).
//
import Testing
@testable import AriKit

@Suite struct GlobalSourcesTests {
    @Test func globalRecallReturnsOneSourcePerMeetingWithBoundedExcerpts() {
        let matches = [
            TranscriptSearchResult(
                id: "meeting-1",
                title: "AI review",
                matchContext: "First matching segment.",
                timestamp: "00:05",
                meetingDate: "2026-07-13",
                summary: "{\"markdown\":\"Saved decision.\"}"
            ),
            TranscriptSearchResult(
                id: "meeting-1",
                title: "AI review",
                matchContext: "Second matching segment.",
                timestamp: "00:30",
                meetingDate: "2026-07-13",
                summary: nil
            ),
            TranscriptSearchResult(
                id: "meeting-2",
                title: "Other review",
                matchContext: "Another meeting.",
                timestamp: "00:10",
                meetingDate: "2026-07-12",
                summary: nil
            )
        ]

        let sources = Recall.buildGlobalSources(matches)
        #expect(sources.count == 2)
        #expect(sources[0].meetingId == "meeting-1")
        #expect(sources[0].matchContext.contains("First matching segment"))
        #expect(sources[0].matchContext.contains("Second matching segment"))
        #expect(sources[0].summary == "Saved decision.")
    }
}
