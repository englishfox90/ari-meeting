//
//  ThinkTagSplitter.swift — pure incremental `<think>…</think>` stream splitter
//  (docs/plans/ask-meetings-agentic-tools.md §3.1/§5.2/§8.1, Slice 1).
//
//  Qwen3's "thinking" mode emits its reasoning as literal `<think>…</think>` text interleaved
//  with the answer inside plain generation chunks — mlx-swift-lm's `Generation` enum has no
//  separate reasoning case (plan §2.4), so the split has to happen in application code. This is
//  that split: a tiny state machine over string deltas that never needs the whole stream buffered
//  — it only ever holds back the minimal suffix that could still be a tag prefix, so memory stays
//  bounded regardless of how much answer/thinking text has already streamed.
//
//  Consumed by `MLXClient.respondWithTools` (AriKitEngineMLX, Slice 1) and, for defense-in-depth,
//  by `RecallEngine`'s rung-2/3 stream mapping (Slice 2) in case a non-MLX model leaks reasoning
//  tags. Zero MLX dependency — pure `Foundation`, unit-tested here with no model in the loop.
//
import Foundation

/// Splits a `<think>…</think>`-tagged text stream into `AgenticEvent.thinking` / `.answerDelta`
/// events, one incremental delta at a time. Tolerant of tags split across arbitrary chunk
/// boundaries (even a single character at a time) and of multiple think blocks in one stream.
///
/// An unterminated `<think>` at end-of-stream is flushed as thinking (never leaked into the
/// answer) — the model presumably ran out of budget mid-reasoning; treating that leftover as
/// user-visible answer text would be worse than dropping it into the (already ephemeral,
/// never-persisted, plan §5.3) thinking channel. A dangling *partial* open tag that never actually
/// completed (e.g. trailing `"<thi"` at EOS) is NOT a think block — it's ordinary text that
/// happened to start with `<`, so it flushes as answer text, matching plain no-tags passthrough.
///
/// **Asymmetric-open mode** (`init(startsInsideThink: true)`, docs/plans/
/// ask-meetings-agentic-tools.md §9 risk 1 addendum, found live 2026-07-23 against the real
/// `mlx-community/Qwen3.5-4B-MLX-4bit` checkout): that checkpoint's chat template injects the
/// literal `<think>` opener into the GENERATION PROMPT (not the completion) whenever
/// `enable_thinking` is on, so the model's own output stream never contains an opening tag — only
/// a lone `</think>` closing it. A splitter that only ever looks for a symmetric pair would never
/// leave `.outsideThink`, leaking the entire reasoning span (plus the literal `</think>` marker)
/// into `.answerDelta`. `startsInsideThink: true` begins the state machine already inside a think
/// block, so the very first `</think>` seen (whenever/wherever it lands, including split across
/// chunk boundaries or as the first character) closes it; a LATER symmetric `<think>…</think>`
/// pair (should the model ever emit one after that point) is still recognized normally, since
/// `outsideThink` behavior is completely unchanged. If EOS arrives with no `</think>` ever seen,
/// `flush()` resolves everything still buffered as `.thinking` — never reclassified as answer text
/// at end-of-stream, even though the whole turn produced no answer (the caller's existing
/// empty-result handling is the honest response to that, not a `ThinkTagSplitter` decision).
public struct ThinkTagSplitter: Sendable {
    private enum Mode: Sendable {
        case outsideThink
        case insideThink
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var mode: Mode
    /// The unresolved tail of everything consumed so far: either ordinary text that might still
    /// turn out to be the start of a tag, or (inside a think block) reasoning text that might
    /// still turn out to be the start of the close tag. Bounded to at most `tag.count - 1`
    /// characters between `consume` calls — never the whole stream.
    private var pending: String = ""

    /// - Parameter startsInsideThink: `false` (default) is the byte-identical symmetric-tag
    ///   behavior this type shipped with; `true` begins already inside a think block for
    ///   checkpoints whose chat template injects the opening `<think>` into the prompt rather than
    ///   the completion (see the asymmetric-open mode doc above).
    public init(startsInsideThink: Bool = false) {
        mode = startsInsideThink ? .insideThink : .outsideThink
    }

    /// Feeds one text delta (of any size — a whole chunk, a word, even a single character) and
    /// returns the events it resolves. Held-back partial-tag text is not returned yet; it surfaces
    /// on a later `consume` (once disambiguated) or on `flush()` at end-of-stream.
    public mutating func consume(_ delta: String) -> [AgenticEvent] {
        guard !delta.isEmpty else { return [] }
        pending += delta
        return drain(atEnd: false)
    }

    /// Call once at end-of-stream. Resolves anything a final `consume` could still be waiting on
    /// (an unterminated `<think>` flushes as `.thinking`; unresolved plain text flushes as
    /// `.answerDelta`) and never needs calling again.
    public mutating func flush() -> [AgenticEvent] {
        var events = drain(atEnd: true)
        if !pending.isEmpty {
            switch mode {
            case .insideThink:
                events.append(.thinking(pending))
            case .outsideThink:
                events.append(.answerDelta(pending))
            }
            pending = ""
        }
        return events
    }

    // MARK: - Internals

    private mutating func drain(atEnd: Bool) -> [AgenticEvent] {
        var events: [AgenticEvent] = []
        while true {
            switch mode {
            case .outsideThink:
                if let range = pending.range(of: Self.openTag) {
                    let before = String(pending[pending.startIndex ..< range.lowerBound])
                    if !before.isEmpty {
                        events.append(.answerDelta(before))
                    }
                    pending = String(pending[range.upperBound...])
                    mode = .insideThink
                    continue
                }
                if atEnd {
                    return events
                }
                emitOutsideHeldBack(&events)
                return events

            case .insideThink:
                if let range = pending.range(of: Self.closeTag) {
                    let before = String(pending[pending.startIndex ..< range.lowerBound])
                    if !before.isEmpty {
                        events.append(.thinking(before))
                    }
                    pending = String(pending[range.upperBound...])
                    mode = .outsideThink
                    continue
                }
                if atEnd {
                    return events
                }
                emitInsideHeldBack(&events)
                return events
            }
        }
    }

    /// No open tag found yet in `pending`: emit everything except a trailing suffix that could
    /// still grow into `"<think>"`, so a tag split across chunk boundaries is never mis-emitted
    /// as answer text.
    private mutating func emitOutsideHeldBack(_ events: inout [AgenticEvent]) {
        let holdBack = Self.longestSuffixMatchingPrefix(of: pending, of: Self.openTag)
        emitHeldBack(holdBack, into: &events) { .answerDelta($0) }
    }

    private mutating func emitInsideHeldBack(_ events: inout [AgenticEvent]) {
        let holdBack = Self.longestSuffixMatchingPrefix(of: pending, of: Self.closeTag)
        emitHeldBack(holdBack, into: &events) { .thinking($0) }
    }

    private mutating func emitHeldBack(
        _ holdBack: Int,
        into events: inout [AgenticEvent],
        wrap: (String) -> AgenticEvent
    ) {
        let emitCount = pending.count - holdBack
        guard emitCount > 0 else { return }
        let emitEnd = pending.index(pending.startIndex, offsetBy: emitCount)
        let toEmit = String(pending[pending.startIndex ..< emitEnd])
        events.append(wrap(toEmit))
        pending = String(pending[emitEnd...])
    }

    /// Longest suffix of `buffer` that equals a prefix of `tag` (capped at `tag.count - 1`, since a
    /// full match would already have been found by `range(of:)`). Zero when no such overlap exists.
    private static func longestSuffixMatchingPrefix(of buffer: String, of tag: String) -> Int {
        let maxLength = min(buffer.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        var length = maxLength
        while length > 0 {
            if buffer.suffix(length) == tag.prefix(length) {
                return length
            }
            length -= 1
        }
        return 0
    }
}
