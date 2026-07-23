//
//  SeriesLedgerCitationsTests.swift — ported verbatim from
//  `ari-engine/src/meeting_series/ledger_citations.rs`'s `#[cfg(test)] mod tests`.
//
import Testing
@testable import AriKit

@Suite("Series ledger citations (F9 meeting-attributed @mref)")
struct SeriesLedgerCitationsTests {
    @Test("Qualifies a single @ref")
    func qualifiesSingleRef() {
        let input = "- Ship the beta @ref(04:21)"
        #expect(SeriesLedgerCitations.qualifyRefs(input, memberIndex: 2) == "- Ship the beta @mref(m2@04:21)")
    }

    @Test("Qualifies multiple refs with the same index")
    func qualifiesMultipleRefsWithSameIndex() {
        let input = "Decision @ref(1:02) and action @ref(12:30) and late @ref(1:05:09)."
        #expect(
            SeriesLedgerCitations.qualifyRefs(input, memberIndex: 3) ==
                "Decision @mref(m3@1:02) and action @mref(m3@12:30) and late @mref(m3@1:05:09)."
        )
    }

    @Test("Qualifies the legacy bracket form")
    func qualifiesLegacyBracketForm() {
        let input = "Marcus owned signoff [01:05]"
        #expect(SeriesLedgerCitations.qualifyRefs(input, memberIndex: 1) == "Marcus owned signoff @mref(m1@01:05)")
    }

    @Test("Passthrough when there are no refs")
    func passthroughWhenNoRefs() {
        let input = "## Decisions\n- We agreed to delay launch.\nSee doc [link](http://x/1:2)."
        #expect(SeriesLedgerCitations.qualifyRefs(input, memberIndex: 4) == input)
    }

    @Test("Does not match plain numbers or dates")
    func doesNotMatchPlainNumbersOrDates() {
        let input = "Budget was 4:21 discussed on 2026-07-15, ratio 3:2."
        #expect(SeriesLedgerCitations.qualifyRefs(input, memberIndex: 1) == input)
    }

    @Test("Validate keeps in-range markers")
    func validateKeepsInRange() {
        let input = "Do X @mref(m1@04:21) and Y @mref(m3@10:00)."
        #expect(SeriesLedgerCitations.validateQualifiedRefs(input, memberCount: 3) == input)
    }

    @Test("Validate drops out-of-range markers to plain time")
    func validateDropsOutOfRangeToPlainTime() {
        let input = "Ok @mref(m1@04:21) but bogus @mref(m9@10:00) here."
        #expect(
            SeriesLedgerCitations.validateQualifiedRefs(input, memberCount: 3) ==
                "Ok @mref(m1@04:21) but bogus 10:00 here."
        )
    }

    @Test("Validate drops a zero index")
    func validateDropsZeroIndex() {
        let input = "Bad @mref(m0@00:30)."
        #expect(SeriesLedgerCitations.validateQualifiedRefs(input, memberCount: 5) == "Bad 00:30.")
    }

    @Test("Validate passthrough without markers")
    func validatePassthroughWithoutMarkers() {
        let input = "## Recurring themes\n- Pricing keeps coming up."
        #expect(SeriesLedgerCitations.validateQualifiedRefs(input, memberCount: 2) == input)
    }

    @Test("Roundtrip qualify then validate")
    func roundtripQualifyThenValidate() {
        let summary = "- Delay launch @ref(34:43)\n- Sign off @ref(01:05)"
        let qualified = SeriesLedgerCitations.qualifyRefs(summary, memberIndex: 2)
        // Model preserved them → all in range → validation is a no-op.
        #expect(SeriesLedgerCitations.validateQualifiedRefs(qualified, memberCount: 4) == qualified)
        #expect(qualified.contains("@mref(m2@34:43)"))
        #expect(qualified.contains("@mref(m2@01:05)"))
    }
}
