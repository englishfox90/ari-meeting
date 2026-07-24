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
            ("meetings with Sarah regarding the roadmap", "sarah"),
            // Regression (caught live 2026-07-23): a bare trailing time word must not get
            // swallowed into the name — "ryan today" never matches a real "Ryan Chadwick" row.
            ("Do I have a meeting with Ryan today?", "ryan"),
            ("Did I meet with Sarah this morning?", "sarah"),
            ("meeting with Ryan yesterday", "ryan"),
            ("meetings with Sarah recently", "sarah")
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

    // MARK: - Positive: single-meeting lookup shape

    @Test(
        "Recognized meeting-lookup phrasings extract the title/topic",
        arguments: [
            ("Did I have a meeting about the Q3 budget?", "the q3 budget"),
            ("meeting titled Kickoff", "kickoff"),
            ("meeting called All Hands", "all hands"),
            (
                "Did I have a meeting about Kaye Lynn taking over the GPM role?",
                "kaye lynn taking over the gpm role"
            )
        ]
    )
    func meetingLookupExtractsTitle(question: String, expectedTitle: String) {
        let intent = RecallIntentClassifier.classify(question)
        #expect(intent == .meetingLookup(titleQuery: expectedTitle))
    }

    @Test("A person-lookup phrase is never misclassified as a meeting lookup")
    func personTriggerTakesPrecedenceOverMeetingTrigger() {
        // Contains "about" (a meeting-trigger qualifier context) but is unambiguously a
        // person-lookup shape — personTriggers must win.
        let intent = RecallIntentClassifier.classify("meetings with Sarah about the Q3 budget")
        #expect(intent == .personMeetings(nameQuery: "sarah"))
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
