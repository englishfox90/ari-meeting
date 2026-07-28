//
//  MarginaliaLedgerActionItemTests.swift — the tolerant ledger status-marker parser, exercised
//  against real shapes surveyed directly from stored `seriesLedger.ledgerMarkdown` (read-only
//  `sqlite3` inspection of `~/Library/Application Support/com.arivo.ari/ari.sqlite`, never
//  written to).
//
import Testing
@testable import AriKit

@Suite("MarginaliaLedgerActionItem status parsing")
struct MarginaliaLedgerActionItemTests {

    @Test("no marker: text returned byte-for-byte unchanged, status nil (No-Fake-State)")
    func noMarker() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "Paul Fox-Reeks: Build concrete plan for high-good ops/product responsibility."
        )
        #expect(text == "Paul Fox-Reeks: Build concrete plan for high-good ops/product responsibility.")
        #expect(status == nil)
    }

    @Test("a table cell that IS just the marker collapses to empty text")
    func isolatedTableCell() {
        for (raw, expected) in [
            ("(still open)", MarginaliaLedgerStatus.stillOpen),
            ("(new)", .new),
            ("**(done)**", .done),
            ("(dropped)", .dropped)
        ] {
            let (text, status) = MarginaliaLedgerActionItem.extractStatus(from: raw)
            #expect(text == "", "raw: \(raw)")
            #expect(status == expected, "raw: \(raw)")
        }
    }

    @Test("bare unlabeled parenthetical, trailing in a sentence")
    func bareUnlabeled() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "Alex Briceno: Provide feedback to Hayden regarding rushed dealership visits and lack of organization. (new)"
        )
        #expect(text ==
            "Alex Briceno: Provide feedback to Hayden regarding rushed dealership visits and lack of organization.")
        #expect(status == .new)
    }

    @Test("bold unlabeled parenthetical, followed by more prose (not consumed)")
    func boldUnlabeled() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "Discuss Caitlin Harrison's transition and payment management takeover with Jacob/Peter @mref(m1@18:24). **(done)** Owner: Paul Fox-Reeks."
        )
        #expect(status == .done)
        #expect(text ==
            "Discuss Caitlin Harrison's transition and payment management takeover with Jacob/Peter @mref(m1@18:24). Owner: Paul Fox-Reeks.")
    }

    @Test("Status: label (plain), with a following @mref citation preserved")
    func labeledPlain() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "Ray Shelton: Revisit application process to confirm quiz step status. Status: (new) @mref(m1@01:48)"
        )
        #expect(status == .new)
        #expect(text == "Ray Shelton: Revisit application process to confirm quiz step status. @mref(m1@01:48)")
        // The literal word "status" that occurs naturally in the prose (not as a "Status:"
        // label) must NOT be mistaken for the marker.
        #expect(text.contains("quiz step status."))
    }

    @Test("Status: label with a bolded parenthetical and a Ref: label — from the exact literal example")
    func labeledBoldWithRef() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "**Erin Paxton**: Schedule follow-up meeting for next Thursday at 11:30 AM. Status: (new). Ref: @mref(m1@07:06)."
        )
        #expect(status == .new)
        #expect(text ==
            "**Erin Paxton**: Schedule follow-up meeting for next Thursday at 11:30 AM. Ref: @mref(m1@07:06).")
    }

    @Test("bolded marker after a Status: label")
    func labeledBoldMarker() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "**Taylor Prows** — Talk to KL about weekly meetings. Status: **(new)**. Ref: @mref(m2@08:29)."
        )
        #expect(status == .new)
        #expect(text == "**Taylor Prows** — Talk to KL about weekly meetings. Ref: @mref(m2@08:29).")
    }

    @Test("lowercase, bold-worded label: — **status**: (still open)")
    func boldedLabelWord() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "Paul Fox-Reeks: Announce GPM hiring decision (Ryan) — **status**: (still open) @mref(m1@03:39)"
        )
        #expect(status == .stillOpen)
        #expect(text == "Paul Fox-Reeks: Announce GPM hiring decision (Ryan) — @mref(m1@03:39)")
    }

    @Test("the whole 'Status: (new)' clause bracket-wrapped")
    func bracketedLabeledClause() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "Paul Fox-Reeks: Share formalized workflow map regarding Trish's role. [Status: (new)] @mref(m1@15:11)"
        )
        #expect(status == .new)
        #expect(text == "Paul Fox-Reeks: Share formalized workflow map regarding Trish's role. @mref(m1@15:11)")
    }

    @Test("a bare marker bracket-wrapped with NO link target")
    func bracketedBareNoLink() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "Tricia Layton: Follow up with James from Equifax to ensure contract passes his desk @mref(m1@24:06) [(new)]"
        )
        #expect(status == .new)
        #expect(text ==
            "Tricia Layton: Follow up with James from Equifax to ensure contract passes his desk @mref(m1@24:06)")
    }

    @Test("a bare marker markdown-link-wrapped WITH a link target")
    func bracketedBareWithLink() {
        let (text, status) = MarginaliaLedgerActionItem.extractStatus(
            from: "**Erika Manning** - Conduct user interviews (new/returning) and analyze app store data to identify drop-off points. [(new)](#action-items)"
        )
        #expect(status == .new)
        #expect(text ==
            "**Erika Manning** - Conduct user interviews (new/returning) and analyze app store data to identify drop-off points.")
        // The unrelated "(new/returning)" earlier in the sentence must NOT be mistaken for the
        // marker — it isn't a bare `(new)`, so it's left untouched.
        #expect(text.contains("(new/returning)"))
    }

    @Test("dropped and still-open both parse; still-open tolerates a hyphen")
    func remainingVocabulary() {
        #expect(MarginaliaLedgerActionItem.extractStatus(from: "(dropped)").status == .dropped)
        #expect(MarginaliaLedgerActionItem.extractStatus(from: "(still-open)").status == .stillOpen)
        #expect(MarginaliaLedgerActionItem.extractStatus(from: "(STILL OPEN)").status == .stillOpen)
    }

    @Test("an unrecognized parenthetical word (Decisions' own vocabulary) is never mistaken for a status")
    func unrecognizedVocabularyIsIgnored() {
        let (text, status) = MarginaliaLedgerActionItem
            .extractStatus(from: "Team ownership structure. Status: (decided)")
        #expect(status == nil)
        #expect(text == "Team ownership structure. Status: (decided)")
    }

    @Test("MarginaliaLedgerStatus.label is Title Case of the pinned vocabulary")
    func statusLabels() {
        #expect(MarginaliaLedgerStatus.new.label == "New")
        #expect(MarginaliaLedgerStatus.stillOpen.label == "Still open")
        #expect(MarginaliaLedgerStatus.done.label == "Done")
        #expect(MarginaliaLedgerStatus.dropped.label == "Dropped")
    }
}
