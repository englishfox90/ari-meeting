//
//  MLXS1DualRunTests.swift — plan §1.6, docs/plans/arikit-engine-extras.md, Track E.
//
//  ⚠️ Scope of this Swift-side suite (documented honestly rather than faked): the S1 gate's full
//  metric recomputation (citation validity ≥ 96.1%, owner attribution ≥ 96.4%, name grounding
//  ≥ 91.3%, `arikit-engine-providers.md §6 Slice E`) is scored today by
//  `tools/prompt-harness/compare.mjs` against the 9 real fixture meetings in the app's SQLite DB
//  — a Node tool with read-only DB access and its own citation/attribution parsers
//  (`compare.mjs`'s regex-based scoring, `README.md` §"Objective comparison"). Re-deriving that
//  exact scoring pipeline in Swift (with no access to a real meetings DB inside this package's
//  test sandbox) is out of this slice's scope per the task's "get it to compile; you do NOT run
//  the inference/dual-run gate" boundary.
//
//  What THIS suite proves instead, on a real Metal machine with
//  `ARIKIT_MLX_LIVE_TESTS=1`: that the **product path** (`MLXClient` → `ModelHost` →
//  `ChatSession`, not the throwaway spike CLI) can execute the same S1 prompt shape end-to-end
//  and produce non-empty, non-leaking output — i.e. it reproduces the *mechanism* S1 proved.
//  The orchestrator closes the actual meet-or-beat gate by re-running
//  `tools/prompt-harness/{run,compare}.mjs` (or an equivalent Swift-side port, a follow-up not in
//  this slice) against real transcripts on real hardware — see plan §1.4/§1.6/§4 sequencing.
//
import AriKit
import Foundation
import Testing
@testable import AriKitEngineMLX

private var mlxLiveTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["ARIKIT_MLX_LIVE_TESTS"] == "1"
}

@Suite(
    .enabled(
        if: mlxLiveTestsEnabled,
        "requires ARIKIT_MLX_LIVE_TESTS=1 + a Metal-toolchain build + the Qwen3.5-4B-4bit model downloaded — the real S1 meet-or-beat gate is closed separately via tools/prompt-harness/{run,compare}.mjs on real transcripts (plan §1.6)"
    )
)
struct MLXS1DualRunTests {
    /// Mirrors the S1 spike's Call ③ shape (system = section instructions, user =
    /// `<transcript_chunks>` — `tools/prompt-harness/README.md` "What Call ③ is") closely enough
    /// to prove the product path runs the identical `ChatSession` construction the spike proved,
    /// without re-deriving the harness's full prompt assembly here.
    private static let sampleCallThreeSystem = """
    You are a meeting-summary assistant. Produce a concise report with a "## Decisions" section \
    and a "## Action Items" section. Reference moments using @ref(MM:SS) markers tied to real \
    transcript timestamps only — never invent a timestamp.
    """

    private static let sampleCallThreeUser = """
    <transcript_chunks>
    [00:12] Sarah: Let's ship the v2 API by Friday.
    [00:47] Tom: Agreed — I'll own the migration script.
    [01:30] Sarah: I'll write the release notes.
    </transcript_chunks>
    """

    @Test func productPathReproducesCallThreeShapeWithoutThinkLeak() async throws {
        let client = MLXClient(
            config: ProviderConfig(kind: .mlx, model: "mlx-community/Qwen3.5-4B-MLX-4bit")
        )

        let result = try await client.generate(
            LLMRequest(system: Self.sampleCallThreeSystem, user: Self.sampleCallThreeUser)
        )

        #expect(!result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!result.contains("<think>"))
        #expect(!result.contains("</think>"))
        // Real citation-validity / owner-attribution / name-grounding scoring against the 9
        // fixture meetings (the actual S1 meet-or-beat comparison) happens in
        // `tools/prompt-harness/compare.mjs`, not here — see file header.
    }

    @Test func streamingProducesTheSameShapeAsGenerate() async throws {
        let client = MLXClient(
            config: ProviderConfig(kind: .mlx, model: "mlx-community/Qwen3.5-4B-MLX-4bit")
        )

        var streamed = ""
        for try await chunk in client.stream(
            LLMRequest(system: Self.sampleCallThreeSystem, user: Self.sampleCallThreeUser)
        ) {
            streamed += chunk
        }

        #expect(!streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!streamed.contains("<think>"))
    }
}
