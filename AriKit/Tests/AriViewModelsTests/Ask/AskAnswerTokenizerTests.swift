//
//  AskAnswerTokenizerTests.swift — plan §10 test 14 (docs/plans/ari-ask-ui.md): text runs +
//  citation + timestamp segments, plus a bare-citation-with-zero-sources sanity check (resolution
//  against `sources` — and any out-of-range fallback — is the VIEW's job, not the tokenizer's).
//
import Foundation
import Testing
@testable import AriViewModels

@Suite("AskAnswerTokenizer")
struct AskAnswerTokenizerTests {
    @Test("mixed text/citation/timestamp segments, in order")
    func mixedSegments() {
        let result = AskAnswerTokenizer.tokenize("a [S1] b @ref(01:30) c")
        #expect(result == [
            .text("a "),
            .citation(index: 1),
            .text(" b "),
            .timestamp("01:30"),
            .text(" c"),
        ])
    }

    @Test("a bare [S1] with zero sources still tokenizes as a citation — resolution is the view's job")
    func bareCitationWithNoSurroundingText() {
        let result = AskAnswerTokenizer.tokenize("[S1]")
        #expect(result == [.citation(index: 1)])
    }

    @Test("legacy bare [MM:SS] tolerated as a timestamp")
    func legacyBareTimestamp() {
        let result = AskAnswerTokenizer.tokenize("see [12:34] for detail")
        #expect(result == [
            .text("see "),
            .timestamp("12:34"),
            .text(" for detail"),
        ])
    }

    @Test("plain text with no markers is a single text segment")
    func plainText() {
        let result = AskAnswerTokenizer.tokenize("just an answer, no markers")
        #expect(result == [.text("just an answer, no markers")])
    }

    @Test("multi-digit citation index")
    func multiDigitCitation() {
        let result = AskAnswerTokenizer.tokenize("per [S12]")
        #expect(result == [.text("per "), .citation(index: 12)])
    }
}
