//
//  MLXActivityTracker.swift — process-wide "is MLX generation in flight" ledger.
//
//  Root-caused crash (2026-07-22, Ari-2026-07-22-222811.ips): the app quit (`NSApp.terminate`,
//  no `applicationShouldTerminate` gate) while a background `Task` was still mid-generation
//  inside `ChatSession`/`TokenIterator`. macOS process termination reaches `exit()` on the main
//  thread, which runs C++ static destructors — including mlx-swift-lm's global
//  `mlx::core::scheduler::Scheduler` — while a *different* thread (the Swift-Concurrency
//  cooperative pool) was still calling into `CustomKernel::eval_gpu`, touching mlx-core global
//  state that was being torn down concurrently. That's a data race on process-exit static
//  destruction, not a race between two overlapping generations (mlx-swift-lm's `ModelContainer`
//  already serializes concurrent callers via its internal `SerialAccessContainer`/`AsyncMutex` —
//  visible in the crash's own background-thread stack). The fix is to never let `exit()` run
//  while this counter is non-zero: the app's `NSApplicationDelegate` gates
//  `applicationShouldTerminate(_:)` on `MLXActivityTracker.shared.isIdle`.
//
//  `actor` isolation, not a lock/atomic — this crosses task boundaries (increment from `generate`/
//  `stream`'s call site, decrement on every exit path of the same async context, awaited-on from
//  the app's termination handler) with no `@unchecked Sendable` needed.
//
import Foundation

/// Tracks in-flight `MLXClient.generate`/`stream` calls process-wide, so the app can defer
/// termination until MLX's GPU work has actually drained — see file header for why this exists.
public actor MLXActivityTracker {
    public static let shared = MLXActivityTracker()

    private var activeCount = 0
    /// Continuations parked on `waitUntilIdle()` while `activeCount > 0`; all resumed the moment
    /// the count returns to zero. Keyed so a cancelled waiter can withdraw just itself.
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public var isIdle: Bool { activeCount == 0 }

    /// Call at the start of a generation; pair with `end()` in a `defer` at the same call site.
    func begin() {
        activeCount += 1
    }

    /// Call when a generation completes (success, throw, or cancellation) — on every exit path,
    /// exactly once per `begin()`.
    ///
    /// If this call is the one that drains `activeCount` to zero, `reclaim` runs FIRST — while the
    /// slot is still counted, so `isIdle` stays `false` and any `waitUntilIdle()` waiter (the app's
    /// termination gate, `AppDelegate.awaitMLXIdle()`) remains parked — and only *then* are waiters
    /// resumed. This ordering is load-bearing: `reclaim` is an mlx-core call (`MLX.Memory.
    /// clearCache()`), and resuming the termination waiter lets `exit()` proceed on the main thread,
    /// which tears down mlx-core static globals. Running `reclaim` after the waiters resumed (an
    /// earlier form of this code) would let `clearCache()` race that teardown — the same
    /// two-threads-in-mlx-core-during-exit data race this whole tracker exists to prevent (see file
    /// header, `Ari-2026-07-22-222811.ips`). Because the whole method is one actor-isolated critical
    /// section, no `begin()`/`end()` can interleave between the reclaim and the waiter resume.
    ///
    /// `reclaim` is synchronous by design (it must complete before this method returns); the default
    /// no-op keeps `end()` usable as a plain decrement (tests, any non-reclaiming caller).
    ///
    /// - Returns: `true` iff this call drained `activeCount` to zero (i.e. it ran `reclaim`).
    @discardableResult
    func end(reclaimingWhenIdle reclaim: @Sendable () -> Void = {}) -> Bool {
        precondition(activeCount > 0, "MLXActivityTracker.end() called without a matching begin()")
        let willBeIdle = activeCount == 1
        // Reclaim BEFORE decrementing: the gate (waitUntilIdle) still sees a non-zero count, so
        // `exit()` stays blocked until clearCache() has fully run.
        if willBeIdle { reclaim() }
        activeCount -= 1
        if activeCount == 0 {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters.values {
                waiter.resume()
            }
        }
        return willBeIdle
    }

    /// Suspends until `isIdle` becomes true (returns immediately if already idle).
    ///
    /// Cancellation-aware: cancelling the awaiting task resumes it promptly (withdrawing its
    /// waiter) instead of leaving a continuation parked forever. The app's termination path
    /// depends on this — its bounding timeout cancels the wait, and `withTaskGroup` awaits all
    /// children at scope exit, so a non-cancellable waiter would silently defeat the timeout and
    /// make a wedged generation block quit indefinitely.
    public func waitUntilIdle() async {
        if activeCount == 0 { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Re-check inside the actor-isolated registration: the count may have drained
                // (or the task been cancelled) across the suspension points above.
                if activeCount == 0 || Task.isCancelled {
                    continuation.resume()
                } else {
                    idleWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.withdrawWaiter(id) }
        }
    }

    /// Resumes and removes a single parked waiter (no-op if it already resumed via `end()`).
    private func withdrawWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }
}
