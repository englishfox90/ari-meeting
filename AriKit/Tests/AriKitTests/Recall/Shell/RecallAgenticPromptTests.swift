//
//  RecallAgenticPromptTests.swift — asserts the tool-first agentic system prompt (plan
//  `ask-meetings-agentic-tools.md` §4.2) carries the attendance-vs-mention rule added to fix the
//  2026-07-23 live-test failure B (a search_transcripts excerpt merely MENTIONING a name was read
//  as evidence the user MET WITH that person).
//
import Testing
@testable import AriKit

@Suite("Recall.agenticSystemPrompt — attendance-vs-mention rule")
struct RecallAgenticPromptTests {
    @Test("prompt states attendance is a calendar/attendee fact, never inferred from a transcript mention")
    func promptCarriesAttendanceVsMentionRule() {
        let prompt = Recall.agenticSystemPrompt()
        #expect(prompt.contains("MET WITH"))
        #expect(prompt.contains("never something you infer from a transcript excerpt"))
        #expect(prompt.contains("was discussed in"))
    }

    @Test("prompt still carries the scheduled-vs-recorded rule")
    func promptStillCarriesScheduledVsRecordedRule() {
        let prompt = Recall.agenticSystemPrompt()
        #expect(prompt.contains("scheduled, never that it was recorded or discussed"))
    }

    @Test("seriesLedger variant appends the ledger sentence on top of the base prompt")
    func seriesLedgerVariantAppendsLedgerSentence() {
        let base = Recall.agenticSystemPrompt()
        let withLedger = Recall.agenticSystemPrompt(seriesLedger: "some ledger text")
        #expect(withLedger.hasPrefix(base))
        #expect(withLedger.contains("running series ledger"))
    }
}
