//
//  QuestionScopeTests.swift — plan §6 Slice 1 test 2.
//
//  1:1 port of the Rust `recall_refuses_product_scope_outside_saved_meetings` case (shell.rs:498).
//
import Testing
@testable import AriKit

@Suite struct QuestionScopeTests {
    @Test func refusesProductScopeOutsideSavedMeetings() {
        #expect(Recall.isUnsupportedRecallQuestion("Search the internet for this"))
        #expect(Recall.isUnsupportedRecallQuestion("Check my email inbox"))
        #expect(!Recall.isUnsupportedRecallQuestion("What decision did we make?"))
        // Calendar is now in scope (linked event context is injected), so calendar-topic
        // questions are answered best-effort rather than hard-refused.
        #expect(!Recall.isUnsupportedRecallQuestion("What did we decide about the calendar rollout?"))
    }
}
