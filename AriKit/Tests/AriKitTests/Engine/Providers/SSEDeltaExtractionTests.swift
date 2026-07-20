//
//  SSEDeltaExtractionTests.swift — plan §6 Slice B.
//
//  Feeds canned SSE text through `SSELineDecoder` (← `extract_delta`, `llm_stream.rs:259-279`, and
//  the per-line loop at `llm_stream.rs:233-252`) and asserts the accumulated text, including
//  `[DONE]`/comment/blank-line handling.
//
import Testing
@testable import AriKit

struct SSEDeltaExtractionTests {
    @Test func openAIStyleDeltasAccumulateAcrossChunksSkippingDoneAndComments() {
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}
        : this is an SSE comment line

        event: message
        data: {"choices":[{"delta":{"content":" world"}}]}
        data: [DONE]
        """
        #expect(SSELineDecoder.accumulate(rawSSE: sse, isClaude: false) == "Hello world")
    }

    @Test func claudeStyleDeltasAccumulate() {
        let sse = """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" there"}}
        data: [DONE]
        """
        #expect(SSELineDecoder.accumulate(rawSSE: sse, isClaude: true) == "Hi there")
    }

    @Test func blankAndNonDataLinesYieldNoDelta() {
        #expect(SSELineDecoder.delta(forLine: "", isClaude: false) == nil)
        #expect(SSELineDecoder.delta(forLine: "event: message", isClaude: false) == nil)
        #expect(SSELineDecoder.delta(forLine: ": comment", isClaude: false) == nil)
    }

    @Test func doneSentinelYieldsNoDeltaWithOrWithoutASpace() {
        #expect(SSELineDecoder.delta(forLine: "data: [DONE]", isClaude: false) == nil)
        #expect(SSELineDecoder.delta(forLine: "data:[DONE]", isClaude: false) == nil)
    }

    @Test func unparsableJSONYieldsNoDeltaRatherThanThrowing() {
        #expect(SSELineDecoder.delta(forLine: "data: not-json", isClaude: false) == nil)
    }

    @Test func missingDeltaPathYieldsNoDeltaRatherThanCrashing() {
        #expect(SSELineDecoder.delta(forLine: "data: {\"choices\":[]}", isClaude: false) == nil)
        #expect(SSELineDecoder.delta(forLine: "data: {}", isClaude: true) == nil)
        #expect(SSELineDecoder.delta(forLine: "data: {\"choices\":[{\"delta\":{}}]}", isClaude: false) == nil)
    }

    @Test func emptyDeltaTextYieldsNilNotEmptyString() {
        // ← `if !delta.is_empty()` gate (llm_stream.rs:248) — an empty extracted string is treated
        // as "no delta", same as a missing path.
        #expect(SSELineDecoder
            .delta(forLine: "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}", isClaude: false) == nil)
    }
}
