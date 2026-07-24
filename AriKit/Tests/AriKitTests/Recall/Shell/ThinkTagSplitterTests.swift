//
//  ThinkTagSplitterTests.swift — plan §8.1 matrix.
//
//  Pure, no MLX in the loop: feeds `ThinkTagSplitter` string deltas at various granularities
//  (whole-chunk, arbitrarily split, single-character) and asserts the accumulated `.thinking` /
//  `.answerDelta` text matches expectations regardless of how the input was chunked.
//
import Testing
@testable import AriKit

struct ThinkTagSplitterTests {
    /// Concatenates every `.thinking`/`.answerDelta` payload (in emission order) into two strings.
    /// `.toolStarted`/`.toolFinished` never appear from this splitter — asserted absent here.
    private func accumulate(_ events: [AgenticEvent]) -> (thinking: String, answer: String) {
        var thinking = ""
        var answer = ""
        for event in events {
            switch event {
            case let .thinking(text):
                thinking += text
            case let .answerDelta(text):
                answer += text
            case .toolStarted, .toolFinished:
                Issue.record("ThinkTagSplitter must never emit tool-activity events")
            }
        }
        return (thinking, answer)
    }

    /// Feeds every chunk in `chunks` through `consume`, then `flush()`, and returns the
    /// accumulated (thinking, answer) text.
    private func run(_ chunks: [String], startsInsideThink: Bool = false) -> (thinking: String, answer: String) {
        var splitter = ThinkTagSplitter(startsInsideThink: startsInsideThink)
        var events: [AgenticEvent] = []
        for chunk in chunks {
            events += splitter.consume(chunk)
        }
        events += splitter.flush()
        return accumulate(events)
    }

    /// Feeds a whole string one Swift `Character` at a time.
    private func runCharByChar(_ text: String, startsInsideThink: Bool = false) -> (thinking: String, answer: String) {
        run(text.map(String.init), startsInsideThink: startsInsideThink)
    }

    // MARK: - No tags: passthrough

    @Test func noTagsPassthroughWholeChunk() {
        let result = run(["Just a plain answer, no reasoning here."])
        #expect(result.answer == "Just a plain answer, no reasoning here.")
        #expect(result.thinking == "")
    }

    @Test func noTagsPassthroughCharByChar() {
        let text = "Plain text with < and > characters but no real tags."
        let result = runCharByChar(text)
        #expect(result.answer == text)
        #expect(result.thinking == "")
    }

    // MARK: - Whole tag in one chunk

    @Test func wholeThinkBlockInOneChunk() {
        let result = run(["<think>reasoning here</think>the answer"])
        #expect(result.thinking == "reasoning here")
        #expect(result.answer == "the answer")
    }

    // MARK: - Tag split across chunk boundaries

    @Test func openTagSplitAcrossChunks() {
        let result = run(["before <thi", "nk>inner</think> after"])
        #expect(result.answer == "before  after")
        #expect(result.thinking == "inner")
    }

    @Test func closeTagSplitAcrossChunks() {
        let result = run(["<think>inner</thi", "nk> after"])
        #expect(result.thinking == "inner")
        #expect(result.answer == " after")
    }

    @Test func tagsSplitOneCharacterAtATime() {
        let text = "hello <think>deep thought process</think> world, the answer is 42."
        let result = runCharByChar(text)
        #expect(result.answer == "hello  world, the answer is 42.")
        #expect(result.thinking == "deep thought process")
    }

    // MARK: - Text before / between / after tags

    @Test func textBeforeAndAfterSingleBlock() {
        let result = run(["Preface. <think>hmm</think> Conclusion."])
        #expect(result.answer == "Preface.  Conclusion.")
        #expect(result.thinking == "hmm")
    }

    // MARK: - Multiple think blocks

    @Test func multipleThinkBlocksInOneStream() {
        let result = run([
            "Start. <think>first thought</think> middle text <think>second thought</think> end."
        ])
        #expect(result.thinking == "first thoughtsecond thought")
        #expect(result.answer == "Start.  middle text  end.")
    }

    @Test func multipleThinkBlocksCharByChar() {
        let text = "A<think>one</think>B<think>two</think>C"
        let result = runCharByChar(text)
        #expect(result.thinking == "onetwo")
        #expect(result.answer == "ABC")
    }

    // MARK: - Unterminated <think> at end-of-stream

    @Test func unterminatedThinkFlushesAsThinkingNeverLeaksIntoAnswer() {
        let result = run(["Before. <think>reasoning that never ends"])
        #expect(result.answer == "Before. ")
        #expect(result.thinking == "reasoning that never ends")
    }

    @Test func unterminatedThinkAcrossChunksAtEOS() {
        let result = run(["<think>partial rea", "soning still going"])
        #expect(result.thinking == "partial reasoning still going")
        #expect(result.answer == "")
    }

    // MARK: - Dangling partial OPEN tag that never actually completes — plain text, not thinking

    @Test func danglingPartialOpenTagFlushesAsAnswerText() {
        let result = run(["Some text ending in <thi"])
        #expect(result.answer == "Some text ending in <thi")
        #expect(result.thinking == "")
    }

    @Test func danglingPartialCloseTagAtEOSFlushesAsThinking() {
        // The open tag DID complete, so we're inside a think block; the close tag never
        // completes, so the partial "</thi" is itself just unresolved thinking text at flush.
        let result = run(["<think>reasoning</thi"])
        #expect(result.thinking == "reasoning</thi")
        #expect(result.answer == "")
    }

    // MARK: - Incremental delivery: partial-tag text is not prematurely emitted

    @Test func partialOpenTagNotEmittedUntilDisambiguated() {
        var splitter = ThinkTagSplitter()
        let firstEvents = splitter.consume("answer text <thi")
        // Only the unambiguous prefix should have been emitted so far — "<thi" is held back
        // because it could still grow into "<think>".
        let (thinkingSoFar, answerSoFar) = accumulate(firstEvents)
        #expect(answerSoFar == "answer text ")
        #expect(thinkingSoFar == "")

        let secondEvents = splitter.consume("s is not a tag")
        let (thinkingAfter, answerAfter) = accumulate(secondEvents)
        #expect(thinkingAfter == "")
        #expect(answerAfter == "<this is not a tag")
    }

    @Test func emptyDeltaIsANoOp() {
        var splitter = ThinkTagSplitter()
        #expect(splitter.consume("").isEmpty)
        let events = splitter.consume("hello") + splitter.flush()
        #expect(accumulate(events).answer == "hello")
    }

    // MARK: - Asymmetric-open mode (startsInsideThink: true — the real Qwen3.5-4B-MLX-4bit

    // checkpoint's chat-template behavior, found live 2026-07-23: the opener `<think>` is
    // injected into the generation PROMPT, never appears in the completion stream — only the
    // closing `</think>` does).

    @Test func startsInsideThinkDefaultIsFalseByteIdenticalToPlainInit() {
        // `ThinkTagSplitter()` and `ThinkTagSplitter(startsInsideThink: false)` must behave
        // identically — the parameter's default preserves every one of the 15 tests above verbatim.
        var plain = ThinkTagSplitter()
        var explicitFalse = ThinkTagSplitter(startsInsideThink: false)
        let text = "<think>reasoning</think>the answer, with <think>more</think> after."
        let plainEvents = plain.consume(text) + plain.flush()
        let explicitEvents = explicitFalse.consume(text) + explicitFalse.flush()
        #expect(plainEvents == explicitEvents)
    }

    @Test func asymmetricModeClosesOnFirstCloseTagNoLeadingOpenTagNeeded() {
        // No literal "<think>" ever appears — the model only ever emits reasoning text
        // followed by a bare "</think>", exactly like the real checkpoint's output.
        let result = run(
            ["I should check the calendar for this. </think>\n\nHere is the answer."],
            startsInsideThink: true
        )
        #expect(result.thinking == "I should check the calendar for this. ")
        #expect(result.answer == "\n\nHere is the answer.")
        #expect(!result.answer.contains("</think>"))
    }

    @Test func asymmetricModeCloseTagAsVeryFirstToken() {
        let result = run(["</think>Hello, the answer is 42."], startsInsideThink: true)
        #expect(result.thinking == "")
        #expect(result.answer == "Hello, the answer is 42.")
    }

    @Test func asymmetricModeCloseTagSplitAcrossChunkBoundaries() {
        let result = run(
            ["reasoning content </thi", "nk>final answer text"],
            startsInsideThink: true
        )
        #expect(result.thinking == "reasoning content ")
        #expect(result.answer == "final answer text")
    }

    @Test func asymmetricModeCloseTagSplitOneCharacterAtATime() {
        let result = runCharByChar(
            "thinking about the tool call</think>the tool returned this",
            startsInsideThink: true
        )
        #expect(result.thinking == "thinking about the tool call")
        #expect(result.answer == "the tool returned this")
    }

    @Test func asymmetricModeEOSWithNoCloseTagFlushesEverythingAsThinking() {
        // The turn produced no answer at all (e.g. it hit maxTokens mid-reasoning) — flush()
        // must never reclassify buffered reasoning as answer text; the caller's own
        // empty-answer handling is the honest response to a turn with zero `.answerDelta` text.
        let result = run(
            ["still reasoning about which tool to call and never finishing"],
            startsInsideThink: true
        )
        #expect(result.thinking == "still reasoning about which tool to call and never finishing")
        #expect(result.answer == "")
    }

    @Test func asymmetricModeEOSWithNoCloseTagAcrossChunksFlushesAsThinking() {
        let result = run(
            ["partial reasoning ", "that keeps going ", "and never closes"],
            startsInsideThink: true
        )
        #expect(result.thinking == "partial reasoning that keeps going and never closes")
        #expect(result.answer == "")
    }

    @Test func asymmetricModeLaterSymmetricPairStillRecognizedAfterFirstClose() {
        // After the implicit-open block closes, ordinary symmetric `<think>...</think>` pairs (if
        // the model ever emits one later in the same turn) still work exactly as in default mode.
        let result = run(
            ["initial reasoning</think>some answer text <think>a second thought</think> more answer"],
            startsInsideThink: true
        )
        #expect(result.thinking == "initial reasoninga second thought")
        #expect(result.answer == "some answer text  more answer")
    }
}
