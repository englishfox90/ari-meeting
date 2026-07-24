///
///  AgenticTurnAnswerBuffer.swift — the per-turn "hold-back" fix for code review finding M2
///  (`ask-meetings-agentic-tools.md`, 2026-07-23): pre-tool-call chatter must never stream as
///  committed answer text.
///
///  A tool-capable model turn can emit ordinary (non-`<think>`) text BEFORE requesting a tool —
///  e.g. "Let me check." — and mlx-swift-lm's `Generation` stream has no way to know, while that
///  text is arriving, whether the turn will end in a tool call or a final answer. Without holding
///  it back, that chatter streamed live as `.answerDelta`, so "Let me check." (or a fragment from
///  an earlier turn) could become part of the PERSISTED answer if a later turn in the same ask
///  threw before ever producing a real answer.
///
///  This type buffers exactly one turn's non-think text (already `<think>`-split by
///  `ThinkTagSplitter` upstream — `.thinking` events are NEVER held, they stream live throughout)
///  and resolves it once the turn's outcome is known: a turn that requested at least one tool call
///  DISCARDS its held text (never emitted); a turn with zero tool calls FLUSHES it as the final
///  answer. Pure, `Sendable`, zero MLX dependency — the conformer (`MLXClient.respondWithTools`)
///  drives it per turn; this type owns none of the ChatSession-specific machinery.
///
public struct AgenticTurnAnswerBuffer: Sendable {
    private var heldText = ""

    public init() {}

    /// Feeds one event produced by (upstream) `ThinkTagSplitter.consume`/`.flush` for the CURRENT
    /// turn. `.thinking` passes straight through — return it immediately, never held. `.answerDelta`
    /// is accumulated and returns `nil` (not yet emitted — its fate is decided by `resolve`).
    /// `.toolStarted`/`.toolFinished` never originate from a splitter, but pass through unchanged
    /// as defense-in-depth (this buffer is answer-text-only).
    public mutating func absorb(_ event: AgenticEvent) -> AgenticEvent? {
        switch event {
        case .thinking:
            event
        case let .answerDelta(text):
            appendAndReturnNil(text)
        case .toolStarted, .toolFinished:
            event
        }
    }

    private mutating func appendAndReturnNil(_ text: String) -> AgenticEvent? {
        heldText += text
        return nil
    }

    /// Resolves the turn now that its outcome is known, and resets the buffer for the next turn.
    /// - Parameter hadToolCalls: `true` discards any held text (a tool-requesting turn's chatter is
    ///   never the final answer); `false` flushes it as `.answerDelta` (`nil` if nothing was held).
    public mutating func resolve(hadToolCalls: Bool) -> AgenticEvent? {
        defer { heldText = "" }
        guard !hadToolCalls, !heldText.isEmpty else { return nil }
        return .answerDelta(heldText)
    }
}
