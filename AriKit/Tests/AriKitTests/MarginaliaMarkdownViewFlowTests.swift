//
//  MarginaliaMarkdownViewFlowTests.swift — the citation-flow punctuation merge
//  (`MarginaliaMarkdownView.splitLeadingPunctuation`). `MarginaliaFlowLayout` applies a fixed
//  inter-item spacing between every flow item, so a period/comma that immediately trails a
//  citation chip (no intervening whitespace, e.g. `@ref(04:21).`) must be merged INTO that
//  citation's flow item rather than becoming its own word token — otherwise it visibly floats
//  away from the chip it belongs to. `flowItems` itself is private (SwiftUI view internals), so
//  this exercises the pure splitting decision it delegates to directly.
//
import Testing
@testable import AriKit

@Suite("MarginaliaMarkdownView citation trailing-punctuation merge")
struct MarginaliaMarkdownViewFlowTests {

    @Test("a single trailing period is split off")
    func singlePeriod() {
        let (punctuation, rest) = MarginaliaMarkdownView.splitLeadingPunctuation("."[...])
        #expect(punctuation == ".")
        #expect(rest == "")
    }

    @Test("a period immediately followed by more prose: only the period is consumed")
    func periodThenWord() {
        let (punctuation, rest) = MarginaliaMarkdownView.splitLeadingPunctuation(". next word"[...])
        #expect(punctuation == ".")
        #expect(rest == " next word")
    }

    @Test("a run of punctuation (comma then space) merges only the punctuation run")
    func commaBeforeNextClause() {
        let (punctuation, rest) = MarginaliaMarkdownView.splitLeadingPunctuation(", more"[...])
        #expect(punctuation == ",")
        #expect(rest == " more")
    }

    @Test("multiple adjacent punctuation characters all merge (e.g. a closing paren then a period)")
    func multiplePunctuationCharacters() {
        let (punctuation, rest) = MarginaliaMarkdownView.splitLeadingPunctuation(")."[...])
        #expect(punctuation == ").")
        #expect(rest == "")
    }

    @Test("no leading punctuation: nothing is split off")
    func noPunctuation() {
        let (punctuation, rest) = MarginaliaMarkdownView.splitLeadingPunctuation("next word"[...])
        #expect(punctuation == "")
        #expect(rest == "next word")
    }

    @Test("empty input: nothing to split")
    func emptyInput() {
        let (punctuation, rest) = MarginaliaMarkdownView.splitLeadingPunctuation(""[...])
        #expect(punctuation == "")
        #expect(rest == "")
    }

    @Test("whitespace immediately after a citation is NOT treated as punctuation to merge")
    func whitespaceStopsTheRun() {
        let (punctuation, rest) = MarginaliaMarkdownView.splitLeadingPunctuation(" word"[...])
        #expect(punctuation == "")
        #expect(rest == " word")
    }
}
