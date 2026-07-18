//
//  CitationsTests.swift — plan §6 Slice 1 test 6.
//
//  1:1 port of every Rust `citations.rs` test (citations.rs:118-163).
//
import Testing
@testable import AriKit

@Suite struct CitationsTests {
    @Test func parsesTimestampLabels() {
        #expect(Recall.parseTimestampLabel("00:40") == 40)
        #expect(Recall.parseTimestampLabel("2:05") == 125)
        #expect(Recall.parseTimestampLabel("1:02:15") == 3735)
        #expect(Recall.parseTimestampLabel("not available") == nil)
        #expect(Recall.parseTimestampLabel("00:75") == nil)
    }

    @Test func keepsInRangeRefsAndDemotesOutOfRange() {
        // Meeting duration 120s: @ref(01:30)=90s kept; @ref(05:00)=300s demoted to text.
        let answer = "Decision at @ref(01:30). Later note @ref(05:00)."
        #expect(
            Recall.filterRefTimestamps(answer, maxSeconds: 120)
                == "Decision at @ref(01:30). Later note 05:00."
        )
    }

    @Test func stripsAllRefsWhenNoTimeline() {
        let answer = "Global mention @ref(01:30) here."
        #expect(Recall.filterRefTimestamps(answer, maxSeconds: nil) == "Global mention 01:30 here.")
    }

    @Test func keepsValidCitationsAndNormalizesCase() {
        let answer = "We decided it [S1]. Sean owns it [s2]."
        #expect(
            Recall.verifySourceCitations(answer, sourceCount: 2)
                == "We decided it [S1]. Sean owns it [S2]."
        )
    }

    @Test func dropsOutOfRangeAndMalformedCitations() {
        // S3 is out of range (only 2 sources); [SX] and [S] are malformed → untouched.
        let answer = "A [S3] B [S1] C [SX] D [S]"
        #expect(Recall.verifySourceCitations(answer, sourceCount: 2) == "A  B [S1] C [SX] D [S]")
    }

    @Test func leavesOrdinaryBracketsUntouched() {
        let answer = "An array like [1, 2] and a note [see below]."
        #expect(Recall.verifySourceCitations(answer, sourceCount: 5) == answer)
    }
}
