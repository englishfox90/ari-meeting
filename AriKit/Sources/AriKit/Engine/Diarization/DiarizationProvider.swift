//
//  DiarizationProvider.swift — the diarization backend seam (plan §2.2).
//
//  `DiarizationOutput` is the whole-meeting result of one diarizer run; `DiarizationProvider` is
//  the protocol a backend (FluidAudio, or a future replacement) conforms to. Core `AriKit` never
//  imports FluidAudio — `AriKitDiarizationFluidAudio` (D7) supplies the sole real conformer.
//
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
    func prepare() async throws
    /// `samples`: 16 kHz mono `[-1, 1]`. Never called on the capture hot path.
    func diarize(
        samples: [Float],
        hint: SpeakerCountHint,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> DiarizationOutput
}

public enum DiarizationError: Error, Sendable, Equatable {
    case modelsUnavailable(String)
    case audioUnreadable(String)
    /// `.automatic` reached the production path (invariant I4).
    case hintRequired
    case providerFailed(String)
}
