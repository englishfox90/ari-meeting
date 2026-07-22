//
//  SpeakerCountHint.swift — the S3-mandated speaker-count hint (plan §2.2, §2.6).
//
//  Every production diarization run must be driven by a count hint — FluidAudio at auto speaker
//  count collapses multi-speaker mixed audio to one speaker (plan §1, S3 non-negotiable).
//  `.automatic` exists only for the eval rig; `DiarizationService` rejects it (invariant I4).
//
public enum SpeakerCountHint: Sendable, Equatable {
    /// User-asserted room size ("exactly N"). Semantic range `exactRange` (← Rust
    /// `FIXED_SPEAKER_MIN`/`FIXED_SPEAKER_MAX`, tuning.rs:59-60).
    case exact(Int)
    /// Uncertain count ("not sure / at most N", or a calendar/participant-derived prefill the
    /// user left untouched). Semantic range `upperBoundRange`; maps to `min=1, max=N` in the
    /// FluidAudio provider (H3/swift-M1 — the exact min/max mapping is pinned by the D10
    /// entry-gate sweep, plan §5/§9 R4).
    case upperBound(Int)
    /// Eval-rig only — the production path never passes this (`DiarizationError.hintRequired`).
    case automatic

    /// The sane clamp range for a user-asserted exact room size (← Rust `FIXED_SPEAKER_MIN`/
    /// `FIXED_SPEAKER_MAX`, tuning.rs:59-60).
    public static let exactRange = 1 ... 20

    /// The clamp band an uncertain "at most N" count is bounded into before it reaches a
    /// provider. Floored at 2 (below 2, there is nothing to be "uncertain" about) and capped at
    /// 12 (← the calendar-cap clamp, `commands.rs:256`: `(n as usize).clamp(1, 12)` — the floor
    /// differs deliberately here: this range gates a genuinely *uncertain* user/calendar count,
    /// while `.upperBound`'s min=1 clustering-config mapping, not this range's floor, is what
    /// carries Rust's calendar-prior floor of 1 into the provider, per H3).
    public static let upperBoundRange = 2 ... 12

    /// Clamp `n` into `exactRange` and wrap it as `.exact` (← `parse_speaker_count`'s
    /// `Fixed(n.clamp(FIXED_SPEAKER_MIN, FIXED_SPEAKER_MAX))`, tuning.rs:195/206/210).
    public static func clampedExact(_ n: Int) -> SpeakerCountHint {
        .exact(n.clamped(to: exactRange))
    }

    /// Clamp `n` into `upperBoundRange` and wrap it as `.upperBound`.
    public static func clampedUpperBound(_ n: Int) -> SpeakerCountHint {
        .upperBound(n.clamped(to: upperBoundRange))
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
