//
//  StubDiarizationProvider.swift — deterministic `DiarizationProvider` test double (plan §2.2;
//  mirrors `StubTranscriptionProvider.swift`).
//
//  `#if DEBUG`-only: this must never be reachable from a shipped (release) build — a fake
//  provider silently standing in for a real diarizer is exactly what No-Fake-State forbids (plan
//  §7). Every orchestration/VM test runs against this rather than the real FluidAudio backend.
//
#if DEBUG
    public struct StubDiarizationProvider: DiarizationProvider {
        public let providerName: String
        public let embeddingModel: String
        public var available: Bool
        public var prepared: Bool
        public var cannedOutput: DiarizationOutput
        public var prepareError: DiarizationError?
        public var diarizeError: DiarizationError?

        public init(
            providerName: String = "stub",
            embeddingModel: String = "stub-embedding-space",
            available: Bool = true,
            prepared: Bool = true,
            cannedOutput: DiarizationOutput? = nil,
            prepareError: DiarizationError? = nil,
            diarizeError: DiarizationError? = nil
        ) {
            self.providerName = providerName
            self.embeddingModel = embeddingModel
            self.available = available
            self.prepared = prepared
            self.cannedOutput = cannedOutput ?? DiarizationOutput(
                segments: [DiarizedSegment(clusterKey: "S1", startTime: 0, endTime: 1)],
                clusters: [DiarizationCluster(key: "S1", centroid: [1, 0], speechSecs: 1)],
                embeddingModel: embeddingModel,
                dim: 2
            )
            self.prepareError = prepareError
            self.diarizeError = diarizeError
        }

        public func isAvailable() async -> Bool {
            available
        }

        public func prepare() async throws {
            if let prepareError {
                throw prepareError
            }
        }

        public func diarize(
            samples _: [Float],
            hint _: SpeakerCountHint,
            progress: (@Sendable (Double) -> Void)?
        ) async throws -> DiarizationOutput {
            if let diarizeError {
                throw diarizeError
            }
            progress?(1.0)
            return cannedOutput
        }
    }
#endif
