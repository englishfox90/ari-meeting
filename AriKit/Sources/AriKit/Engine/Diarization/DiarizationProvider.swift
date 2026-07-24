///
///  DiarizationProvider.swift — the diarization backend seam (plan §2.2).
///
///  `DiarizationOutput` is the whole-meeting result of one diarizer run; `DiarizationProvider` is
///  the protocol a backend (FluidAudio, or a future replacement) conforms to. Core `AriKit` never
///  imports FluidAudio — `AriKitDiarizationFluidAudio` (D7) supplies the sole real conformer.
///
public struct DiarizationOutput: Sendable {
    public var segments: [DiarizedSegment]
    public var clusters: [DiarizationCluster]
    /// The provider-stamped embedding-space identifier, e.g. "fluidaudio-community-1".
    public var embeddingModel: String
    public var dim: Int

    public init(
        segments: [DiarizedSegment],
        clusters: [DiarizationCluster],
        embeddingModel: String,
        dim: Int
    ) {
        self.segments = segments
        self.clusters = clusters
        self.embeddingModel = embeddingModel
        self.dim = dim
    }
}

/// One diarization backend. `Sendable` so it crosses actor boundaries freely.
public protocol DiarizationProvider: Sendable {
    var providerName: String { get }
    /// The embedding-space identifier all centroids from this provider live in.
    var embeddingModel: String { get }
    func isAvailable() async -> Bool
    /// Download/compile models if needed. Idempotent. Honest errors — never a fake ready state.
    /// `progress`, when supplied, reports a real fraction-complete signal for backends that can
    /// produce one (docs/plans/onboarding-install-flow.md §2.2) — never fabricated. The
    /// zero-argument convenience below (`prepare()`) is the historical call shape and stays
    /// additive/backward-compatible.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    /// `samples`: 16 kHz mono `[-1, 1]`. Never called on the capture hot path.
    func diarize(
        samples: [Float],
        hint: SpeakerCountHint,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> DiarizationOutput
}

/// Convenience default-arg overload, mirroring the historical zero-arg `prepare()` call shape
/// (`DiarizationService.swift:122`'s `try await provider.prepare()`) — additive, not breaking
/// (docs/plans/onboarding-install-flow.md §2.2).
public extension DiarizationProvider {
    func prepare() async throws {
        try await prepare(progress: nil)
    }
}

public enum DiarizationError: Error, Sendable, Equatable {
    case modelsUnavailable(String)
    case audioUnreadable(String)
    /// `.automatic` reached the production path (invariant I4).
    case hintRequired
    case providerFailed(String)
}
