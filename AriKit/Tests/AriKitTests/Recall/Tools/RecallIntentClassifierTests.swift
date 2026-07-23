//
//  RecallIntentClassifierTests.swift — plan §8 Slice B `RecallIntentClassifierTests`
//  (`ask-meetings-tools-and-cards.md`).
//
//  Pure, no DB: table-driven positive cases for each recognized shape, plus explicit negative
//  cases — the regression guard against false positives degrading normal, open-ended Ask.
//
import Testing
@testable import AriKit

@Suite("RecallIntentClassifier — Slice B heuristic classifier")
struct RecallIntentClassifierTests {

    // MARK: - Positive: person-meetings shape

    @Test(
        "Recognized person-lookup phrasings extract the name",
        arguments: [
            ("Last meeting with Sarah", "sarah"),
            ("meetings with Sarah Ammon", "sarah ammon"),
            ("Did I meet with Sarah?", "sarah"),
            ("When was my last meeting with the design lead", "the design lead"),
            ("meetings with Sarah about the budget", "sarah"),
            ("meetings with Sarah regarding the roadmap", "sarah")
        ]
    )
    func personLookupExtractsName(question: String, expectedName: String) {
        let intent = RecallIntentClassifier.classify(question)
        #expect(intent == .personMeetings(nameQuery: expectedName))
    }

    // MARK: - Positive: series-meetings shape

    @Test(
        "Recognized series-lookup phrasings extract the series title",
        arguments: [
            ("meetings in the design team series", "design team"),
            ("What happened in the last meeting in the weekly sync series?", "weekly sync"),
        ]
    )
    func seriesLookupExtractsTitle(question: String, expectedTitle: String) {
        let intent = RecallIntentClassifier.classify(question)
        #expect(intent == .seriesMeetings(titleQuery: expectedTitle))
    }

    // MARK: - Negative: open-ended questions must NOT classify as entity-lookup

    @Test(
        "Open-ended, non-entity-shaped questions never classify",
        arguments: [
            "what did we decide about pricing",
            "what are the open action items",
            "summarize what I've been working on",
            "Hi",
            "What decisions were made recently?",
            "",
            "   ",
        ]
    )
    func openEndedQuestionsDoNotClassify(question: String) {
        #expect(RecallIntentClassifier.classify(question) == nil)
    }

    @Test("A series-shaped sentence with no series title extracts nothing and falls through")
    func malformedSeriesPhraseFallsThrough() {
        // "in the series" with nothing between "the" and "series" — no real title to extract.
        #expect(RecallIntentClassifier.classify("meetings in the series") == nil)
    }
}
