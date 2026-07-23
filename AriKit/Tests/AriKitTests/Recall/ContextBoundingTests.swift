//
//  ContextBoundingTests.swift — plan §6 Slice 1 test 4.
//
//  1:1 port of the Rust `meeting_recall_context_keeps_the_start_and_conclusion` (shell.rs:543) and
//  `recall_context_includes_real_date_summary_and_transcript_once_per_meeting` (shell.rs:568).
//
//  DIVERGENCE FROM THE RUST PORT (live 2026-07-23 timezone bug): the Rust source interpolated
//  `source.meetingDate`'s raw RFC3339 UTC string straight into the prompt, so the model relabeled
//  the raw 24-hour UTC digits AM/PM with no offset shift (a 14:46 UTC = 8:46 AM MDT meeting was
//  reported "2:46 PM"). `buildContext` now converts the stored UTC instant to a LOCAL human string
//  first; the assertions below are updated to expect that, and to inject an explicit non-UTC zone
//  so the conversion is proven regardless of the CI machine's own timezone.
//
import Foundation
import Testing
@testable import AriKit

struct ContextBoundingTests {
    /// `Date.FormatStyle` renders AM/PM after a narrow no-break space (U+202F), not an ASCII space;
    /// normalize it so time assertions read naturally and don't depend on that codepoint.
    private func normalizeSpaces(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func meetingRecallContextKeepsStartAndConclusion() {
        let longSegment = "Henry opened the meeting. "
            + String(repeating: "middle ", count: 2000)
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

    @Test func contextIncludesRealDateSummaryAndTranscriptOncePerMeeting() throws {
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

        // Denver (MDT, UTC-6 in July): 2026-07-13T10:00:00Z is 4:00 AM local. The prompt must show
        // the converted LOCAL time, never the raw UTC string.
        let denver = try #require(TimeZone(identifier: "America/Denver"))
        let enUS = Locale(identifier: "en_US")
        let context = Recall.buildContext(sources, timeZone: denver, locale: enUS)
        #expect(context.contains("meeting date Jul 13, 2026"))
        #expect(normalizeSpaces(context).contains("4:00 AM"))
        #expect(!context.contains("2026-07-13T10:00:00Z"))
        #expect(!context.contains("10:00")) // the raw UTC hour must never survive into the prompt
        #expect(context.contains("Saved summary:\n## Decisions"))
        #expect(context.contains("Transcript excerpt:\nHenry opened"))
        #expect(context.components(separatedBy: "Saved summary:").count - 1 == 1)
    }

    /// Regression (live-caught 2026-07-23): a meeting recorded at 8:46 AM MDT is stored as
    /// `14:46 UTC`; the old code interpolated that raw UTC string and the model relabeled the
    /// digits "2:46 PM". The built context must now carry the real LOCAL 12-hour time. Injecting an
    /// explicit non-UTC zone means this can only pass if a genuine UTC→local conversion happened —
    /// it does not depend on the CI machine's own timezone.
    @Test func buildContextShowsRealLocalTimeNotRawUTC() throws {
        let denver = try #require(TimeZone(identifier: "America/Denver")) // UTC-6 in July (MDT)
        let enUS = Locale(identifier: "en_US")
        let sources = [
            RecallSource(
                meetingId: "meeting-ryan",
                title: "Ryan 1:1",
                matchContext: "Good catchup with Ryan.",
                timestamp: "00:05",
                meetingDate: "2026-07-23T14:46:29Z", // 8:46 AM MDT
                summary: nil
            )
        ]

        let context = Recall.buildContext(sources, timeZone: denver, locale: enUS)
        #expect(normalizeSpaces(context).contains("8:46 AM"))
        #expect(!normalizeSpaces(context).contains("2:46 PM")) // the wrong relabel the model produced live
        #expect(!context.contains("14:46")) // no raw 24-hour UTC digits
        #expect(!context.contains("Z")) // no raw RFC3339 zone marker
    }

    /// Regression (day-boundary variant of the same class of bug): a meeting recorded at 11:30 PM
    /// MDT on Jul 22 is stored as `05:30 UTC on Jul 23`. Slicing the RFC3339 date prefix would print
    /// "Jul 23" — the wrong local calendar day. The built context must show the real local day,
    /// "Jul 22, 2026". Only passes if the timezone shift crossed the date line.
    @Test func buildContextShowsRealLocalDayAcrossUTCMidnight() throws {
        let denver = try #require(TimeZone(identifier: "America/Denver")) // UTC-6 in July (MDT)
        let enUS = Locale(identifier: "en_US")
        let sources = [
            RecallSource(
                meetingId: "meeting-latenight",
                title: "Late night sync",
                matchContext: "Wrapped up late.",
                timestamp: "00:05",
                meetingDate: "2026-07-23T05:30:00Z", // 11:30 PM MDT on Jul 22
                summary: nil
            )
        ]

        let context = Recall.buildContext(sources, timeZone: denver, locale: enUS)
        #expect(context.contains("Jul 22, 2026"))
        #expect(!context.contains("Jul 23, 2026")) // the wrong UTC-prefix day
        #expect(!context.contains("2026-07-23T05:30:00Z"))
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
