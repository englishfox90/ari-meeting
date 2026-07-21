//
//  MLXClientSmokeTests.swift — plan §1.6, docs/plans/arikit-engine-extras.md, Track E.
//
//  ⚠️ NOT part of the headless `swift test` lane. Real MLX inference needs a Metal-toolchain
//  build (a bare `swift build` produces no `.metallib`, plan §1.4) plus the Qwen3.5-4B-4bit model
//  downloaded from Hugging Face. An agent cannot close this gate in the sandbox — this suite is
//  gated behind `ARIKIT_MLX_LIVE_TESTS=1` (unset in CI/headless `swift test`) so it degrades to a
//  clean, reported *skip* rather than a failure when the lane isn't provisioned. Run explicitly on
//  a real Apple-silicon machine via:
//
//      ARIKIT_MLX_LIVE_TESTS=1 xcodebuild test -scheme AriKitEngineMLX ...
//
//  (or `ARIKIT_MLX_LIVE_TESTS=1 swift test --filter MLXClientSmokeTests` on a machine with the
//  Metal toolchain provisioned — plan §1.4 notes a bare `swift build` alone won't load the model
//  at runtime).
//
import AriKit
import Foundation
import Testing
@testable import AriKitEngineMLX

/// The HF repo id the S1 spike closed GO on (`swift-migration-plan.md:104`) — kept as a single
/// source of truth here so both tests below reference the same model.
private let s1RepoID = "mlx-community/Qwen3.5-4B-MLX-4bit"

private var mlxLiveTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["ARIKIT_MLX_LIVE_TESTS"] == "1"
}

@Suite(
    .enabled(
        if: mlxLiveTestsEnabled,
        "requires ARIKIT_MLX_LIVE_TESTS=1 + a Metal-toolchain build + the Qwen3.5-4B-4bit model downloaded from Hugging Face — real MLX inference, not exercised by headless `swift test` (plan §1.4/§1.6)"
    )
)
struct MLXClientSmokeTests {
    @Test func generatesNonEmptyTextWithoutThinkLeak() async throws {
        let client = MLXClient(config: ProviderConfig(kind: .mlx, model: s1RepoID))
        let result = try await client.generate(
            LLMRequest(
                system: "You are a concise meeting-summary assistant. Reply in one short sentence.",
                user: "Summarize: Sarah and Tom agreed to ship the v2 API by Friday."
            )
        )

        #expect(!result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // ← proves `additionalContext: ["enable_thinking": false]` (MLXClient.swift) took effect —
        // the hard Qwen3.x carry-forward from the S1 spike (plan §1.3).
        #expect(!result.contains("<think>"))
        #expect(!result.contains("</think>"))
    }

    @Test func unregisteredRepoIDThrowsProviderUnavailableNotFabricatedText() async {
        let client = MLXClient(
            config: ProviderConfig(kind: .mlx, model: "mlx-community/definitely-not-a-real-repo-id")
        )

        do {
            _ = try await client.generate(LLMRequest(system: "s", user: "u"))
            Issue.record("expected .providerUnavailable for an unresolvable repo id")
        } catch LLMError.providerUnavailable {
            // expected — No-Fake-State (plan §1.7): an unloadable model is honest, never fabricated.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
