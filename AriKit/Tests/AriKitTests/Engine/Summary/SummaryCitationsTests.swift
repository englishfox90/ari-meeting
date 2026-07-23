//
//  SummaryCitationsTests.swift — plan §6 Slice F (← summary/citations.rs `#[cfg(test)]`, 1:1).
//
//  ⚠️ Distinct from `Recall/CitationsTests.swift` (the already-ported recall citations) — see
//  the plan §2.5 conflation warning and `SummaryCitations.swift`'s header.
//
import Testing
@testable import AriKit

struct SummaryCitationsTests {
    static let fixtureTranscript = """
    [00:12] Paul: Let's kick off the beta review.
    [01:05] Marcus: I'll own getting the beta build signed off by Friday.
    [02:30] Paul: Sounds good, thanks Marcus.
    [10:00] Paul: Let's also talk about the pricing page redesign.
    [10:20] Priya: I can lead the pricing page redesign this sprint.
    [34:43] Paul: One more thing - we decided to delay the launch to next month.
    [35:01] Marcus: Agreed, launch delay makes sense given the beta timeline.

    """

    @Test func exactRefIsVerifiedAndKeptUnchanged() {
        let summary = "- Marcus owns the beta signoff @ref(01:05)"
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(out.contains("@ref(01:05)"))
        #expect(stats.verified == 1)
        #expect(stats.snapped == 0)
        #expect(stats.dropped == 0)
    }

    @Test func nearMissRefIsSnappedToRealMarker() {
        let summary = "- Launch delayed to next month @ref(34:38)"
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(out.contains("@ref(34:43)"))
        #expect(!out.contains("@ref(34:38)"))
        #expect(stats.snapped == 1)
        #expect(stats.verified == 0)
        #expect(stats.dropped == 0)
    }

    @Test func outOfRangeRefIsDropped() {
        let summary = "- Something claimed to happen late @ref(99:59)"
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(!out.contains("@ref(99:59)"))
        #expect(!out.contains("@ref("))
        #expect(stats.dropped == 1)
        #expect(stats.verified == 0)
        #expect(stats.snapped == 0)
    }

    @Test func emptyTableRefCellIsBackfilledOnStrongOverlap() {
        let summary = """
        ## Action Items

        | Owner | Action | Ref |
        | --- | --- | --- |
        | Marcus | I'll own getting the beta build signed off by Friday | None |
        """
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(stats.backfilled == 1)
        #expect(out.contains("@ref(01:05)"))
        // The "None" placeholder must be gone, replaced by the citation.
        #expect(!out.contains("| None |"))
    }

    @Test func tableRefCellLeftBlankWhenOverlapIsWeak() {
        let summary = """
        ## Action Items

        | Owner | Action | Ref |
        | --- | --- | --- |
        | Someone | Do a totally unrelated thing with no transcript match | None |
        """
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(stats.backfilled == 0)
        #expect(!out.contains("@ref("))
        // Left as-is (still "None"): omission over fabrication.
        #expect(out.contains("| None |"))
    }

    @Test func decisionBulletWithoutRefGetsBackfilledOnStrongMatch() {
        let summary = """
        ## Key Decisions

        - Decided to delay the launch to next month
        """
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(stats.backfilled == 1)
        #expect(out.contains("@ref(34:43)"))
    }

    @Test func prosePargraphIsNeverModified() {
        let summary = """
        ## Summary

        This was a productive meeting about the beta build and the pricing page redesign, with no explicit timestamps mentioned anywhere in this prose paragraph.

        """
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(out == summary)
        #expect(stats.backfilled == 0)
        #expect(stats.verified == 0)
        #expect(stats.snapped == 0)
        #expect(stats.dropped == 0)
    }

    // MARK: - Pass 0: promoting bare (MM:SS) parentheticals into badges

    @Test func bareParenTimestampMatchingRealMarkerIsPromotedToRef() {
        // The small model wrote plain "(01:05)" instead of the instructed "@ref(01:05)".
        let summary = "Marcus owns the beta signoff (01:05)."
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(out.contains("@ref(01:05)"))
        #expect(!out.contains("signoff (01:05)")) // the bare paren form is gone
        #expect(stats.verified == 1) // promoted → verified by pass 1 (exact match)
    }

    @Test func bareParenTimestampNearAMarkerSnapsWhenPromoted() {
        let summary = "Launch delayed (34:38)." // 5s from the real 34:43, inside tolerance
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(out.contains("@ref(34:43)")) // promoted to @ref, then snapped by pass 1
        #expect(!out.contains("(34:38)"))
        #expect(stats.snapped == 1)
    }

    @Test func bareParenTimestampWithNoRealMarkerIsLeftAsPlainText() {
        // (55:00) matches no transcript marker → never fabricated into a badge, never deleted.
        let summary = "Some unrelated aside (55:00)."
        let (out, stats) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(out == summary)
        #expect(stats.verified == 0)
        #expect(stats.snapped == 0)
        #expect(stats.dropped == 0)
    }

    @Test func existingRefParenIsNotDoublePromoted() {
        // The "(" inside an existing @ref(...) must not be touched by the promotion pass.
        let summary = "Marcus owns the beta signoff @ref(01:05)."
        let (out, _) = SummaryCitations.applyCitations(summary, sourceTranscript: Self.fixtureTranscript)
        #expect(out.contains("@ref(01:05)"))
        #expect(!out.contains("@ref(@ref"))
        #expect(!out.contains("ref(ref("))
    }
}
