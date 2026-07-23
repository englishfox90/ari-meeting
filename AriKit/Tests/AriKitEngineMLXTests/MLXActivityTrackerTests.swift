//
//  MLXActivityTrackerTests.swift — regression coverage for the crash fixed 2026-07-22
//  (Ari-2026-07-22-222811.ips): app termination racing a live MLX generation. See
//  `MLXActivityTracker.swift` and `AppDelegate.swift` (Ari app target) for the full writeup.
//
//  These tests exercise the tracker in isolation — no real MLX/Metal needed — so they run in the
//  headless `swift test` lane (unlike `MLXClientSmokeTests`/`MLXS1DualRunTests`, which need a
//  Metal-toolchain build + a downloaded model and are gated behind `ARIKIT_MLX_LIVE_TESTS=1`).
//
import Synchronization
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

    /// The exact property the GPU-cache reclaim depends on (`MLXClient.endActivityReclaimingCacheIfIdle`,
    /// memory OOM fixed 2026-07-23): the reclaim closure runs ONLY on the transition back to idle,
    /// so `MLX.Memory.clearCache()` fires exactly once when all work drains — never mid-flight of an
    /// overlapping generation.
    @Test func reclaimRunsOnlyOnTheDrainingTransition() async {
        let tracker = MLXActivityTracker()
        let counter = ReclaimCounter()

        await tracker.begin()
        await tracker.begin()

        // First end() leaves one generation in flight → not idle → must NOT reclaim.
        #expect(await tracker.end(reclaimingWhenIdle: { counter.bump() }) == false)
        #expect(counter.count == 0)
        // Second end() drains to zero → the idle transition → reclaim exactly here.
        #expect(await tracker.end(reclaimingWhenIdle: { counter.bump() }) == true)
        #expect(counter.count == 1)

        // A fresh single begin/end also reports the transition and reclaims.
        await tracker.begin()
        #expect(await tracker.end(reclaimingWhenIdle: { counter.bump() }) == true)
        #expect(counter.count == 2)
    }

    /// The load-bearing ordering (BLOCKER fixed 2026-07-23): the reclaim closure must run BEFORE a
    /// parked `waitUntilIdle()` waiter resumes. That waiter is the app's termination gate
    /// (`AppDelegate.awaitMLXIdle` → `exit()`), and the reclaim is an mlx-core call
    /// (`clearCache()`); if the waiter resumed first, `exit()`'s static-destructor teardown of
    /// mlx-core globals could race the reclaim — the very crash class this tracker prevents. We
    /// assert the reclaim was observed by the time the awaiting task returns.
    @Test func reclaimCompletesBeforeIdleWaiterResumes() async {
        let tracker = MLXActivityTracker()
        let order = ReclaimCounter()

        await tracker.begin()

        let waiter = Task {
            await tracker.waitUntilIdle()
            order.recordWaiterResumedAt() // stamps the reclaim count visible at resume time
        }

        // Let the waiter actually suspend inside waitUntilIdle() before we drain.
        try? await Task.sleep(for: .milliseconds(50))
        await tracker.end(reclaimingWhenIdle: { order.bump() })

        await waiter.value
        // The reclaim (bump → count 1) must have already run when the waiter resumed.
        #expect(order.countSeenByWaiter == 1)
    }
}

/// Test-only shared counter, `Sendable` via `Mutex` (not `@unchecked`) so the `@Sendable` reclaim
/// closure — which runs synchronously inside the `MLXActivityTracker` actor, off the main actor —
/// can mutate it, and the waiter task can read it, without data races.
private final class ReclaimCounter: Sendable {
    private let state = Mutex(State(count: 0, seenByWaiter: -1))
    private struct State { var count: Int; var seenByWaiter: Int }

    var count: Int { state.withLock { $0.count } }
    var countSeenByWaiter: Int { state.withLock { $0.seenByWaiter } }
    func bump() { state.withLock { $0.count += 1 } }
    func recordWaiterResumedAt() { state.withLock { $0.seenByWaiter = $0.count } }
}
