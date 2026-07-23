//
//  MLXModelInstaller.swift — the on-device MLX summary model's `OnboardingInstallableComponent`
//  conformer (docs/plans/onboarding-install-flow.md §2.3). NOT `MLXClient` (the *inference*
//  conformer) — this is *installation*: calling `ensureReady` warms the SAME `ModelHost` cache
//  `MLXClient.resolveContainer()` reads at first real summary generation (`MLXClient.swift:
//  179-187`), so onboarding's download is never wasted/duplicated work.
//
//  `HubCache`'s real on-disk layout (verified against the vendored `swift-huggingface` 0.9.0
//  checkout, `AriKit/.build/checkouts/swift-huggingface/Sources/HuggingFace/Hub/HubCache.swift`
//  + `Shared/CacheLocationProvider.swift`, per plan §9 risk #1): the default cache directory is
//  resolved by `CacheLocationProvider.environment` (`HF_HUB_CACHE` → `HF_HOME`/hub →
//  `~/.cache/huggingface/hub`, or the sandboxed Caches-dir fallback), and a repo's own directory
//  under it is `<kind.pluralized>--<namespace>--<name>` (`HubCache.repoDirectory(repo:kind:)`,
//  `HubCache.swift:114-118`) — e.g. `models--mlx-community--Qwen3.5-4B-MLX-4bit`. `swift-huggingface`
//  exposes NO documented "is this repo id already fully cached" check independent of attempting a
//  download/snapshot fetch, so `quickPresenceHint()` below is the same honesty-level fallback the
//  diarization/embedding conformers use: a non-empty repo directory is a HINT, never a guarantee.
//
import AriKit
import Foundation
import HuggingFace
import MLXLMCommon

public struct MLXModelInstaller: OnboardingInstallableComponent, Sendable {
    public let componentID: OnboardingComponentID = .summaryModel
    public let displayName = "On-device summary model"

    private let repoId: String
    private let host: ModelHost
    private let cache: HubCache

    /// - Parameters:
    ///   - repoId: the HF repo id to install. Defaults to the app's real summary model
    ///     (`AriKitEngineMLX.defaultModelID`, `mlx-community/Qwen3.5-4B-MLX-4bit`).
    ///   - host: the `ModelHost` actor to resolve the warm `ModelContainer` through. Defaults to
    ///     the process-wide `.shared` cache — same singleton `MLXClient` resolves against, so
    ///     onboarding and first-summary-generation share exactly one cache, never two.
    ///   - cache: the `HubCache` used only for `quickPresenceHint()`'s best-effort filesystem
    ///     check. Defaults to `.default` (real auto-detected HF cache dir); tests inject a fixed
    ///     temp-directory cache so they never touch the real machine's HF cache.
    public init(
        repoId: String = AriKitEngineMLX.defaultModelID,
        host: ModelHost = .shared,
        cache: HubCache = .default
    ) {
        self.repoId = repoId
        self.host = host
        self.cache = cache
    }

    public func quickPresenceHint() async -> Bool {
        Self.presenceHint(repoId: repoId, cache: cache)
    }

    /// Pure, testable core of `quickPresenceHint()`: `true` iff the repo's cache directory exists
    /// and is non-empty. A hint, never authoritative — a partial/corrupt download would also hint
    /// `true`, and `ensureReady` below does the real work regardless of this hint's value.
    static func presenceHint(repoId: String, cache: HubCache) -> Bool {
        guard let id = Repo.ID(rawValue: repoId) else { return false }
        let repoDirectory = cache.repoDirectory(repo: id, kind: .model)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: repoDirectory.path)
        return !(contents?.isEmpty ?? true)
    }

    /// Resolves (downloading/loading if needed) the `ModelContainer` for `repoId` through the
    /// SAME `ModelHost` cache the app's real summary generation uses. `Foundation.Progress`
    /// (the `ModelHost.container(forRepoId:progressHandler:)` shape) is adapted to
    /// `OnboardingInstallProgress.downloading(fractionCompleted:)` — never a fabricated fraction;
    /// `Progress.fractionCompleted` is `0.0` until the underlying download reports real bytes, so
    /// this only reports what the download stack itself knows. `ModelHost` is single-flight: only
    /// the FIRST concurrent caller for a given `repoId` receives progress callbacks (a warm-cache
    /// hit here — e.g. a prior successful `ensureReady`, or the app already having generated a
    /// summary — completes near-instantly with no progress calls at all, which is itself honest:
    /// there is no download to report on).
    public func ensureReady(
        progress: (@Sendable (OnboardingInstallProgress) -> Void)?
    ) async throws {
        progress?(.checking)
        do {
            _ = try await host.container(forRepoId: repoId) { foundationProgress in
                progress?(.downloading(fractionCompleted: foundationProgress.fractionCompleted))
            }
        } catch {
            throw LLMError.providerUnavailable("MLX model \"\(repoId)\" is unavailable: \(error)")
        }
    }
}
