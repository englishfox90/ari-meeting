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
/// event pair, `stream.rs:11-14`).
public enum RecallStreamEvent: Sendable {
    /// An incremental text delta (← `ask-stream-delta`'s `{ streamId, delta }`; empty deltas are
    /// never yielded, mirroring `emit_delta`'s `if delta.is_empty() { return; }` guard,
    /// `stream.rs:244-246`).
    case delta(String)
    /// The authoritative final result (← `ask-stream-done`'s `{ streamId, answer, sources }`):
    /// the FULL answer with citations verified/filtered, and the sources computed independently
    /// of the model. Always the last event; the stream finishes immediately after.
    case done(RecallResponse)
}

public extension RecallEngine {
    /// Streaming counterpart of `answerMeetingsLocally`. Yields `.delta` for every non-empty
    /// token chunk the provider streams, then reconciles citations on the ACCUMULATED full answer
    /// (same invariant as single-shot: drop invented `[S<n>]`, verify/scope `@ref` timestamps) and
    /// yields exactly one terminal `.done` before finishing.
    func answerMeetingsLocallyStream(
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
                    continuation.yield(.done(RecallResponse(answer: reconciled, sources: prepared.sources)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
