//
//  StubLLMClient.swift — deterministic `LLMClient` test double (plan §2.2, Slice A).
//
//  `#if DEBUG`-only: this must never be reachable from a shipped (release) build — a fake client
//  silently standing in for a real provider is exactly what No-Fake-State forbids (plan §7). It
//  exists purely so callers (ProviderFactory's MLX-injection point, the future SummaryService, the
//  recall Orchestrator) can be tested against a canned `generate` + canned stream deltas without
//  any network/Store/MLX dependency.
//
#if DEBUG
    import Foundation

    public struct StubLLMClient: LLMClient {
        public let kind: ProviderKind
        public var cannedResponse: String
        public var cannedDeltas: [String]
        public var error: LLMError?

        public init(
            kind: ProviderKind = .mlx,
            cannedResponse: String = "stub response",
            cannedDeltas: [String]? = nil,
            error: LLMError? = nil
        ) {
            self.kind = kind
            self.cannedResponse = cannedResponse
            self.cannedDeltas = cannedDeltas ?? [cannedResponse]
            self.error = error
        }

        public func generate(_ request: LLMRequest) async throws -> String {
            if let error {
                throw error
            }
            try Task.checkCancellation()
            return cannedResponse
        }

        public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    if let error {
                        continuation.finish(throwing: error)
                        return
                    }
                    for delta in cannedDeltas {
                        if Task.isCancelled {
                            continuation.finish(throwing: LLMError.cancelled)
                            return
                        }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
#endif
