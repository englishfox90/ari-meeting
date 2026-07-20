//
//  StubTranscriptionProvider.swift — deterministic `TranscriptionProvider` test double
//  (plan §5, Slice A; mirrors `StubLLMClient.swift`).
//
//  `#if DEBUG`-only: this must never be reachable from a shipped (release) build — a fake
//  provider silently standing in for a real STT engine is exactly what No-Fake-State forbids
//  (plan §7). It exists purely so callers (the future capture orchestrator, Phase 3.2, and the
//  eval harness) can be tested against canned segments/errors without any Speech framework or
//  device-asset dependency.
//
#if DEBUG
    import Foundation
    import Speech

    public struct StubTranscriptionProvider: TranscriptionProvider {
        public let providerName: String
        public var available: Bool
        public var model: String?
        public var cannedSegments: [TranscriptionSegment]
        public var error: TranscriptionError?

        public init(
            providerName: String = "stub",
            available: Bool = true,
            model: String? = "stub-model",
            cannedSegments: [TranscriptionSegment]? = nil,
            error: TranscriptionError? = nil
        ) {
            self.providerName = providerName
            self.available = available
            self.model = model
            self.cannedSegments = cannedSegments ?? [
                TranscriptionSegment(text: "stub transcript", startSec: 0, endSec: 1, confidence: 1.0, words: [])
            ]
            self.error = error
        }

        public func isAvailable() async -> Bool {
            available
        }

        public func currentModel() async -> String? {
            model
        }

        public func transcribe(fileURL: URL, language: String?) async throws -> TranscriptionResult {
            if let error {
                throw error
            }
            try Task.checkCancellation()
            return TranscriptionResult(
                segments: cannedSegments,
                fullText: cannedSegments.map(\.text).joined(separator: " "),
                audioDurationSec: cannedSegments.last?.endSec,
                wordTimestampCount: cannedSegments.reduce(0) { $0 + $1.words.count }
            )
        }

        public func transcribe(
            liveInputs _: some AsyncSequence<AnalyzerInput, Never> & Sendable,
            language: String?
        ) -> AsyncThrowingStream<TranscriptionSegment, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    if let error {
                        continuation.finish(throwing: error)
                        return
                    }
                    for segment in cannedSegments {
                        if Task.isCancelled {
                            continuation.finish(throwing: TranscriptionError.engineFailed("cancelled"))
                            return
                        }
                        continuation.yield(segment)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
#endif
