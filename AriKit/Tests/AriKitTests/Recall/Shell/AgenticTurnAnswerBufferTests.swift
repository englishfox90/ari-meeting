//
//  AgenticTurnAnswerBufferTests.swift — the per-turn "hold-back" fix for code review finding M2
//  (`ask-meetings-agentic-tools.md`, 2026-07-23).
//
import Testing
@testable import AriKit

@Suite("AgenticTurnAnswerBuffer (M2 — pre-tool-call chatter hold-back)")
struct AgenticTurnAnswerBufferTests {
    @Test("`.thinking` always passes through immediately, never held")
    func thinkingPassesThroughImmediately() {
        var buffer = AgenticTurnAnswerBuffer()
        let emitted = buffer.absorb(.thinking("Considering..."))
        #expect(emitted == .thinking("Considering..."))
    }

    @Test("`.answerDelta` is held (not emitted) until `resolve` decides its fate")
    func answerDeltaIsHeldNotEmitted() {
        var buffer = AgenticTurnAnswerBuffer()
        let emitted = buffer.absorb(.answerDelta("Let me check."))
        #expect(emitted == nil)
    }

    @Test("resolve(hadToolCalls: true) DISCARDS the held chatter — nothing is ever emitted for it")
    func resolveDiscardsHeldChatterWhenToolCallsHappened() {
        var buffer = AgenticTurnAnswerBuffer()
        _ = buffer.absorb(.answerDelta("Let me check."))
        let resolved = buffer.resolve(hadToolCalls: true)
        #expect(resolved == nil, "a turn that went on to call a tool must never leak its chatter as an answer")
    }

    @Test("resolve(hadToolCalls: false) FLUSHES the held text as the final answer")
    func resolveFlushesHeldTextWhenNoToolCallsHappened() {
        var buffer = AgenticTurnAnswerBuffer()
        _ = buffer.absorb(.answerDelta("The "))
        _ = buffer.absorb(.answerDelta("final answer."))
        let resolved = buffer.resolve(hadToolCalls: false)
        #expect(resolved == .answerDelta("The final answer."))
    }

    @Test("resolve with nothing held returns nil either way")
    func resolveWithNothingHeldReturnsNil() {
        var buffer = AgenticTurnAnswerBuffer()
        #expect(buffer.resolve(hadToolCalls: false) == nil)
        #expect(buffer.resolve(hadToolCalls: true) == nil)
    }

    @Test("the buffer resets after resolve — a later turn's chatter is independent of an earlier one's")
    func bufferResetsAfterResolve() {
        var buffer = AgenticTurnAnswerBuffer()
        _ = buffer.absorb(.answerDelta("First turn chatter."))
        _ = buffer.resolve(hadToolCalls: true)

        _ = buffer.absorb(.answerDelta("Second turn's real answer."))
        let resolved = buffer.resolve(hadToolCalls: false)
        #expect(resolved == .answerDelta("Second turn's real answer."))
    }

    @Test(
        "chatter-then-toolcall-then-throw: the chatter is discarded, so a subsequent stream throw before any emitted answer text propagates rather than committing garbage"
    )
    func chatterThenToolCallThenThrowYieldsNoCommittedAnswer() async throws {
        // Mirrors exactly what a FIXED conformer (MLXClient.runToolLoop) now does: chatter is
        // absorbed and held, the turn requests a tool (discarding the chatter via `resolve`), and
        // only `.toolStarted`/`.toolFinished` are ever actually yielded to the stream before a
        // later throw — no `.answerDelta` for the chatter ever reaches the consumer.
        var buffer = AgenticTurnAnswerBuffer()
        var yieldedEvents: [AgenticEvent] = []

        if let emitted = buffer.absorb(.answerDelta("Let me check.")) {
            yieldedEvents.append(emitted)
        }
        if let emitted = buffer.absorb(.toolStarted(name: "search_transcripts")) {
            yieldedEvents.append(emitted)
        }
        if let resolved = buffer.resolve(hadToolCalls: true) {
            yieldedEvents.append(resolved)
        }

        #expect(!yieldedEvents.contains {
            if case .answerDelta = $0 {
                true
            } else {
                false
            }
        })

        // Feeding exactly this event sequence (plus a terminal throw, no answer ever committed)
        // through the SAME `drainAgenticEvents` the real ladder uses proves the caller-visible
        // contract: no answerDelta was ever observed ⇒ a subsequent throw propagates (rung 3 runs).
        let stream = AsyncThrowingStream<AgenticEvent, Error> { continuation in
            for event in yieldedEvents {
                continuation.yield(event)
            }
            struct Boom: Error {}
            continuation.finish(throwing: Boom())
        }
        await #expect(throws: (any Error).self) {
            _ = try await RecallEngine.drainAgenticEvents(stream)
        }
    }
}
