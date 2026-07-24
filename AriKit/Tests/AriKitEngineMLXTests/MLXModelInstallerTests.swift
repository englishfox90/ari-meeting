//
//  MLXModelInstallerTests.swift — acceptance test 6 (docs/plans/onboarding-install-flow.md §7).
//
//  `presenceHint` is pure/filesystem-only and runs in every `swift test` pass — no network, no
//  real HF cache dependency (a fixed temp-directory `HubCache` is injected, exactly like
//  `FluidAudioOnboardingComponentTests`'s fixture-seeded directory).
//
//  `ensureReady` against a REAL repo id is integration-shaped (network + a multi-GB download on
//  a cold cache) and gated behind `ARIKIT_MLX_LIVE_TESTS=1`, mirroring `MLXClientSmokeTests`'s
//  own gate (§1.6) and FluidAudio's `offlineMode` pattern (plan §7) — degrades to a clean,
//  reported *skip* rather than a failure when the lane isn't provisioned.
//
import AriKit
import Foundation
import HuggingFace
import Testing
@testable import AriKitEngineMLX

private var mlxLiveTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["ARIKIT_MLX_LIVE_TESTS"] == "1"
}

@Suite("MLXModelInstaller")
struct MLXModelInstallerTests {
    @Test("componentID and displayName are stable, provider-facing identifiers")
    func componentIdentity() {
        let installer = MLXModelInstaller()
        #expect(installer.componentID == .summaryModel)
        #expect(installer.displayName == "On-device summary model")
    }

    @Test("presenceHint is false against an empty temp cache directory")
    func presenceHintFalseAgainstEmptyCache() throws {
        let tempDir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = HubCache(cacheDirectory: tempDir)

        #expect(MLXModelInstaller.presenceHint(repoId: "mlx-community/Qwen3.5-4B-MLX-4bit", cache: cache) == false)
    }

    @Test("presenceHint is true against a cache pre-seeded with the expected repo directory structure")
    func presenceHintTrueAgainstSeededFixture() throws {
        let tempDir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = HubCache(cacheDirectory: tempDir)
        let repoId = "mlx-community/Qwen3.5-4B-MLX-4bit"

        let repoDirectory = try cache.repoDirectory(repo: #require(Repo.ID(rawValue: repoId)), kind: .model)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: repoDirectory.appendingPathComponent("config.json"))

        #expect(MLXModelInstaller.presenceHint(repoId: repoId, cache: cache) == true)
    }

    @Test("presenceHint is false against an invalid (non namespace/name) repo id")
    func presenceHintFalseForInvalidRepoID() throws {
        let tempDir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = HubCache(cacheDirectory: tempDir)

        #expect(MLXModelInstaller.presenceHint(repoId: "not-a-valid-repo-id", cache: cache) == false)
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXModelInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// ⚠️ NOT part of the headless `swift test` lane — see file header. Run explicitly via:
///
///     ARIKIT_MLX_LIVE_TESTS=1 swift test --filter MLXModelInstallerLiveTests
///
@Suite(
    .enabled(
        if: mlxLiveTestsEnabled,
        "requires ARIKIT_MLX_LIVE_TESTS=1 + a Metal-toolchain build + network access to Hugging Face"
    )
)
struct MLXModelInstallerLiveTests {
    @Test("ensureReady resolves against a real repo id and reuses ModelHost's single-flight cache")
    func ensureReadyReusesModelHostCache() async throws {
        let host = ModelHost()
        let installer = MLXModelInstaller(
            repoId: "mlx-community/Qwen3.5-4B-MLX-4bit",
            host: host
        )

        try await installer.ensureReady(progress: nil)

        // Reuses ModelHost's existing single-flight cache: a second `container(forRepoId:)` call
        // for the SAME repo id after `ensureReady` already resolved it must not trigger a second
        // download/load Task — asserted the same way `ModelHost`'s own tests do, by timing a
        // near-instant resolve.
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await host.container(forRepoId: "mlx-community/Qwen3.5-4B-MLX-4bit")
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(1))
    }
}
