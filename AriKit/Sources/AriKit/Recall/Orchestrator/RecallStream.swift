//
//  RecallStream.swift — the streaming variant of `RecallEngine.answerMeetingsLocally` (plan §5
//  Slice 8, ← `ari-engine/src/recall/stream.rs::api_answer_meetings_locally_stream_impl`).
//
//  Same retrieval, gating, prompt, and citation-verification invariants as the single-shot path —
//  they are reused from `RecallEngine.prepare`/`RecallEngine.reconcile`, not copied (mirrors the
//  Rust source's own note that "the security-relevant gates and the anti-hallucination prompt are
//  single-sourced, not copied", `stream.rs:2-9`). The only different behavior is transport: tokens
//  are yielded incrementally as `.delta`, then a terminal `.done` carries the citation-reconciled
//  full answer plus the separately-computed (never model-invented) sources — replacing the Rust
//  `EventSink` emit of `ask-stream-delta`/`ask-stream-done` with a native `AsyncThrowingStream`
//  (plan §9(6), the resolved streaming-shape decision).
//
import Foundation

/// One event in a streaming Ask-Meetings answer (← the `ask-stream-delta`/`ask-stream-done`
/// event pair, `stream.rs:11-14`; extended by the tool-first agentic path, plan §5.1
/// `ask-meetings-agentic-tools.md`).
public enum RecallStreamEvent: Sendable {
    /// An incremental text delta (← `ask-stream-delta`'s `{ streamId, delta }`; empty deltas are
    /// never yielded, mirroring `emit_delta`'s `if delta.is_empty() { return; }` guard,
    /// `stream.rs:244-246`).
    case delta(String)
    /// A reasoning-text delta (Qwen3 `<think>` content, already stripped of the tags) — ephemeral,
    /// never persisted, never part of the reconciled answer (plan §5.2/§5.3).
    case thinking(String)
    /// One tool-dispatch lifecycle event (plan §5.1) — shown honestly only for a tool that actually
    /// ran (No-Fake-State); never fabricated progress.
    case toolActivity(ToolActivity)
    /// The authoritative final result (← `ask-stream-done`'s `{ streamId, answer, sources }`):
    /// the FULL answer with citations verified/filtered, and the sources computed independently
    /// of the model. Always the last event; the stream finishes immediately after.
    case done(RecallResponse)
}

/// One tool-dispatch lifecycle event, mapped to a Swift-computed (never model-authored) display
/// label (plan §5.1). `toolName` is the raw tool identifier (e.g. `"search_transcripts"`);
/// `displayLabel` is the human-facing string (`AskToolset.displayLabel(for:)`).
public struct ToolActivity: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case started
        case finished(ok: Bool)
    }

    public var toolName: String
    public var displayLabel: String
    public var phase: Phase

    public init(toolName: String, displayLabel: String, phase: Phase) {
        self.toolName = toolName
        self.displayLabel = displayLabel
        self.phase = phase
    }
}

public extension RecallEngine {
    /// Streaming counterpart of `answerMeetingsLocally`. Meeting-scoped asks stay on today's
    /// single-shot-streaming path UNCHANGED (plan §4.5); global/series-scope asks route through the
    /// tool-first agentic path (`RecallEngine+Agentic.swift`), which itself falls back to this exact
    /// streaming pipeline (rung 3, plan §4.4) on any classifier miss/error.
    func answerMeetingsLocallyStream(
        question: String,
        meetingId: MeetingID? = nil,
        seriesId: SeriesID? = nil,
        history: [RecallTurn] = []
    ) -> AsyncThrowingStream<RecallStreamEvent, Error> {
        guard meetingId == nil else {
            return answerMeetingsLocallyStreamSingleShot(
                question: question, meetingId: meetingId, seriesId: seriesId, history: history
            )
        }
        return answerMeetingsLocallyStreamAgentic(question: question, seriesId: seriesId, history: history)
    }

    /// Yields `.delta` for every non-empty token chunk the provider streams, then reconciles
    /// citations on the ACCUMULATED full answer (drop invented `[S<n>]`, verify/scope `@ref`
    /// timestamps) and yields exactly one terminal `.done` before finishing. This is the exact,
    /// byte-identical pre-agentic pipeline — reused verbatim both directly (meeting scope) and as
    /// the agentic ladder's rung-3 fallback (global/series scope).
    func answerMeetingsLocallyStreamSingleShot(
        question: String,
        meetingId: MeetingID? = nil,
        seriesId: SeriesID? = nil,
        history: [RecallTurn] = []
    ) -> AsyncThrowingStream<RecallStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prepared = try await prepare(
                        question: question,
                        meetingId: meetingId,
                        seriesId: seriesId,
                        history: history
                    )
                    let client = try clientFactory(prepared.config)

                    var fullAnswer = ""
                    do {
                        let request = LLMRequest(system: prepared.systemPrompt, user: prepared.userPrompt)
                        for try await delta in client.stream(request) {
                            guard !delta.isEmpty else { continue }
                            fullAnswer += delta
                            continuation.yield(.delta(delta))
                        }
                    } catch {
                        throw RecallEngineError.generationFailed(
                            "The local model could not answer from your saved meetings: \(error)"
                        )
                    }

                    let reconciled = Self.reconcile(
                        answer: fullAnswer,
                        sources: prepared.sources,
                        isMeetingScoped: prepared.isMeetingScoped
                    )
                    continuation.yield(
                        .done(RecallResponse(answer: reconciled, sources: prepared.sources, card: prepared.card))
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
