//
//  MLXActivityTrackerTests.swift — regression coverage for the crash fixed 2026-07-22
//  (Ari-2026-07-22-222811.ips): app termination racing a live MLX generation. See
//  `MLXActivityTracker.swift` and `AppDelegate.swift` (Ari app target) for the full writeup.
//
//  These tests exercise the tracker in isolation — no real MLX/Metal needed — so they run in the
//  headless `swift test` lane (unlike `MLXClientSmokeTests`/`MLXS1DualRunTests`, which need a
//  Metal-toolchain build + a downloaded model and are gated behind `ARIKIT_MLX_LIVE_TESTS=1`).
//
import Testing
@testable import AriKitEngineMLX

@Suite
struct MLXActivityTrackerTests {
    @Test func idleByDefault() async {
        let tracker = MLXActivityTracker()
        #expect(await tracker.isIdle)
    }

    @Test func busyWhileGenerationInFlightThenIdleAfterEnd() async {
        let tracker = MLXActivityTracker()
        await tracker.begin()
        #expect(await tracker.isIdle == false)
        await tracker.end()
        #expect(await tracker.isIdle)
    }

    /// Two concurrent "generations" — the tracker only reports idle once BOTH have ended, mirroring
    /// how the real app could have a summary generation and a title/series-extraction generation
    /// overlapping.
    @Test func staysBusyUntilAllOverlappingGenerationsEnd() async {
        let tracker = MLXActivityTracker()
        await tracker.begin()
        await tracker.begin()
        #expect(await tracker.isIdle == false)

        await tracker.end()
        #expect(await tracker.isIdle == false) // one still in flight

        await tracker.end()
        #expect(await tracker.isIdle)
    }

    /// The exact property the termination-gate fix depends on: a caller awaiting `waitUntilIdle()`
    /// while a generation is in flight suspends until `end()` runs, rather than racing past it (the
    /// shape of the original crash — `exit()` proceeding while GPU work was still live).
    @Test func waitUntilIdleSuspendsUntilEndIsCalled() async {
        let tracker = MLXActivityTracker()
        await tracker.begin()

        let waiter = Task {
            await tracker.waitUntilIdle()
        }

        // Give the waiter a chance to actually suspend inside `waitUntilIdle()` before we end the
        // in-flight generation — otherwise this test could pass even if `waitUntilIdle()` returned
        // immediately (a bug), since the ordering happened to work out.
        try? await Task.sleep(for: .milliseconds(50))
        await tracker.end()

        // Bounded wait for the waiter task to observe completion — proves `waitUntilIdle()` really
        // was gated on `end()`, not a no-op.
        await waiter.value
        #expect(await tracker.isIdle)
    }

    @Test func waitUntilIdleReturnsImmediatelyWhenAlreadyIdle() async {
        let tracker = MLXActivityTracker()
        // No begin() at all — this must not hang.
        await tracker.waitUntilIdle()
        #expect(await tracker.isIdle)
    }
}
