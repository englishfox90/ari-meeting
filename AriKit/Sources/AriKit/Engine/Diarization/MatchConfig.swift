//
//  MatchConfig.swift — tunable thresholds for the dual-gate, three-tier matcher
//  (← Rust `ari-engine/src/diarization/matching.rs` `MatchConfig`).
//
//  Threshold provenance (RETUNE ON REAL RECORDINGS): these are CAM++ starting values, not
//  final tuning for the FluidAudio community-1 embedding space (plan §9 R3) — carried over
//  verbatim as the starting point until the D10 calibration step.
//
public struct MatchConfig: Sendable, Equatable {
    /// Absolute cosine at/above which a top match may auto-confirm (given the margin gate
    /// also passes). Default `0.70`.
    public var autoThreshold: Float = 0.70
    /// Absolute cosine at/above which a top match is worth *suggesting* to the user. Below
    /// this, the speaker is left anonymous. Default `0.55`.
    public var suggestThreshold: Float = 0.55
    /// How far the best match must beat the runner-up to be considered unambiguous. If
    /// `best - runnerUp < margin`, never auto-confirm even when `best >= autoThreshold`.
    /// Default `0.08`.
    public var margin: Float = 0.08
    /// Minimum segment duration (seconds) before an embedding is clean/long enough to fold
    /// into a profile. Default `3.0`.
    public var minEnrollDurationSecs: Float = 3.0
    /// Minimum self-similarity (an embedding compared against its own cluster centroid)
    /// required before folding — the "suspect-cluster guard". Default `0.60`.
    public var minEnrollSelfSimilarity: Float = 0.60

    /// Minimum speech (seconds) a cluster must hold before it may fold into a voiceprint
    /// centroid (P1 quality gate). Shorter clusters are too noisy/uncertain to trust as
    /// identity signal — the match is still kept, only the fold is skipped.
    public static let minFoldSpeechSecs: Double = 5.0
    /// Cap (seconds) applied to a stored voiceprint's `totalSpeechSecs` when used as the fold
    /// weight `W`. Once a voiceprint is "mature" (>= this much folded speech), each new fold
    /// has weight `w / (CAP + w)`, i.e. the centroid behaves as an exponential moving average
    /// and stays adaptive instead of ossifying.
    public static let foldWeightCapSecs: Double = 600.0
    /// Minimum total cluster speech (seconds) required before an `autoConfirm` match may be
    /// trusted without user confirmation.
    public static let minAutoConfirmSpeechSecs: Double = 5.0

    public init() {}
}
