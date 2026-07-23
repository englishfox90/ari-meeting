//
//  AppleContextualEmbedderInstallableTests.swift — acceptance test 7 (docs/plans/
//  onboarding-install-flow.md §7): `AppleContextualEmbedder`'s `OnboardingInstallableComponent`
//  conformance. Mirrors `AppleContextualEmbedderTests`'s asset-availability gating: a clean
//  CI/headless host may not have the model assets downloaded, so tests degrade honestly (skip)
//  rather than hard-failing when the on-device model isn't present.
//
import Foundation
import NaturalLanguage
import os
import Testing
@testable import AriKit

struct AppleContextualEmbedderInstallableTests {
    private static var modelAssetsAvailable: Bool {
        guard let model = NLContextualEmbedding(language: .english) else {
            return false
        }
        return model.hasAvailableAssets
    }

    @Test("componentID and displayName are stable, provider-facing identifiers")
    func componentIdentity() {
        let embedder = AppleContextualEmbedder()
        #expect(embedder.componentID == .embedding)
        #expect(embedder.displayName == "Meeting search embedding model")
    }

    @Test("quickPresenceHint mirrors hasAvailableAssets, never a fabricated availability")
    func quickPresenceHintMirrorsRealAssetState() async {
        let embedder = AppleContextualEmbedder()
        let hint = await embedder.quickPresenceHint()
        #expect(hint == Self.modelAssetsAvailable)
    }

    /// `ensureReady` resolves without error and reports only `.indeterminate` (never a fabricated
    /// fraction) when the on-device model's assets are actually available on this host. Skips
    /// cleanly (no network calls made) when this host has no downloaded assets.
    @Test("ensureReady resolves honestly when assets are available")
    func ensureReadyResolvesWhenAssetsAvailable() async throws {
        guard Self.modelAssetsAvailable else { return }
        let embedder = AppleContextualEmbedder()
        let progressEvents = OSAllocatedUnfairLock<[OnboardingInstallProgress]>(initialState: [])
        try await embedder.ensureReady(progress: { event in
            progressEvents.withLock { $0.append(event) }
        })
        #expect(progressEvents.withLock { $0 }.allSatisfy { event in
            if case .indeterminate = event {
                return true
            }
            return false
        })
    }

    /// A device/language without assets surfaces the SAME `RecallEmbedderError.modelUnavailable`
    /// `embed(_:)` itself would throw — never a fake-ready state. This test only actually asserts
    /// something on a host that genuinely lacks the assets; on a host WITH assets, `ensureReady`
    /// legitimately succeeds (covered by the test above), so there is nothing dishonest to assert
    /// here either way.
    @Test("ensureReady surfaces the honest modelUnavailable error when assets are missing")
    func ensureReadySurfacesHonestErrorWhenAssetsMissing() async {
        guard !Self.modelAssetsAvailable else { return }
        let embedder = AppleContextualEmbedder()
        await #expect(throws: RecallEmbedderError.self) {
            try await embedder.ensureReady(progress: nil)
        }
    }
}
