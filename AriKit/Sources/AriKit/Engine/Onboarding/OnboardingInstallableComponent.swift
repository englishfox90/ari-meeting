//
//  OnboardingInstallableComponent.swift — the unifying seam for the first-run install/education
//  flow (docs/plans/onboarding-install-flow.md §2.1). Mirrors the shape `DiarizationProvider`
//  already established (`DiarizationProvider.swift:29-42`): core `AriKit` never imports
//  FluidAudio/MLXHuggingFace, so this protocol is the provider-agnostic abstraction the concrete
//  conformers (`FluidAudioDiarizationProvider`, `MLXModelInstaller`, `AppleContextualEmbedder`)
//  attach to from their own targets.
//
import Foundation

/// One on-device component this flow can report on / install. `Sendable` so it crosses actor
/// boundaries freely, mirroring `DiarizationProvider`.
public protocol OnboardingInstallableComponent: Sendable {
    var componentID: OnboardingComponentID { get }
    var displayName: String { get }

    /// Best-effort, filesystem-only hint for UI copy ("Already on this Mac" vs "~640 MB
    /// download") — NEVER authoritative and NEVER gates whether `ensureReady` is called.
    /// No-Fake-State: this is presented as a hint, not a guarantee, because none of the three
    /// backends expose a public "is this exactly the right cached model" check.
    func quickPresenceHint() async -> Bool

    /// Ensures the component is ready to use — downloads/compiles if needed, no-ops (fast) if
    /// already cached. Idempotent. Honest errors — never a fake-ready state. `progress` is called
    /// with real provider-reported progress when available; a provider that cannot report
    /// fractional progress calls it with `.indeterminate(phase:)` rather than being skipped
    /// silently, so the UI can still show *a* phase label without fabricating a percentage.
    func ensureReady(progress: (@Sendable (OnboardingInstallProgress) -> Void)?) async throws
}

public enum OnboardingComponentID: String, Sendable, CaseIterable {
    case diarization
    case summaryModel
    case embedding
}

public enum OnboardingInstallProgress: Sendable, Equatable {
    case checking
    case downloading(fractionCompleted: Double)
    case compiling
    /// A provider is doing real work but cannot report a fraction (e.g. Apple's
    /// `NLContextualEmbedding.requestAssets()`). Never fabricate a fraction here.
    case indeterminate(phase: String)
}
