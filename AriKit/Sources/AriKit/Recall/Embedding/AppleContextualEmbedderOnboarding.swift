//
//  AppleContextualEmbedderOnboarding.swift — `AppleContextualEmbedder`'s conformance to
//  `OnboardingInstallableComponent` (docs/plans/onboarding-install-flow.md §2.4). Correcting a
//  task-brief assumption: the embedding model is NOT a no-op "just maybe a ready check" —
//  `NLContextualEmbedding` (unlike the retired static `NLEmbedding`) has its own first-run asset
//  story (`hasAvailableAssets`/`requestAssets()`, an OTA fetch with no progress-fraction API in
//  its public surface), so this conformer is real work, not a stub.
//
import Foundation
import NaturalLanguage

extension AppleContextualEmbedder: OnboardingInstallableComponent {
    public nonisolated var componentID: OnboardingComponentID {
        .embedding
    }

    public nonisolated var displayName: String {
        "Meeting search embedding model"
    }

    /// Best-effort hint: constructing a fresh `NLContextualEmbedding` and checking
    /// `hasAvailableAssets` is cheap (no download triggered) but not authoritative — the actor's
    /// OWN cached `loadedModel` (if any) is not consulted here since this is `nonisolated`
    /// (mirrors the diarization/MLX conformers' "hint, never a guarantee" contract).
    public nonisolated func quickPresenceHint() async -> Bool {
        NLContextualEmbedding(language: .english)?.hasAvailableAssets ?? false
    }

    /// `NLContextualEmbedding.requestAssets() -> AssetsResult` has NO progress-fraction API in
    /// its public surface (a coarse "requesting → available/unavailable" outcome) — hence
    /// `.indeterminate`, never a fabricated percentage (No-Fake-State). Reuses the actor's own
    /// lazy-load path (`loadedModelInstance()`) directly rather than forcing it via a
    /// throwaway-string `embed(_:)` call, so a missing-assets/language failure surfaces as the
    /// SAME honest `RecallEmbedderError.modelUnavailable` `embed(_:)` itself would throw.
    public func ensureReady(
        progress: (@Sendable (OnboardingInstallProgress) -> Void)?
    ) async throws {
        progress?(.indeterminate(phase: "Checking on-device language model…"))
        _ = try await loadedModelInstance()
    }
}
