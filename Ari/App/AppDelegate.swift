//
//  AppDelegate.swift — gates process termination on in-flight MLX generation.
//
//  Root cause (crash 2026-07-22, Ari-2026-07-22-222811.ips): a SwiftUI `App` with no
//  `NSApplicationDelegate` lets `NSApp.terminate(nil)` (the menu-bar "Quit Ari" row, and the
//  standard Cmd+Q SwiftUI wires automatically) proceed straight to `exit()` on the main thread.
//  `exit()` runs C++ static destructors, including mlx-swift-lm's global
//  `mlx::core::scheduler::Scheduler`. The crash caught a *different* thread (the Swift-Concurrency
//  cooperative pool) still inside `CustomKernel::eval_gpu` — a live summary generation — reading a
//  global mlx-core map that was torn down concurrently by the exiting main thread. Two threads
//  touching MLX C++ global state at once, one destroying it: KERN_INVALID_ADDRESS.
//
//  The fix: never let `exit()` run while `MLXActivityTracker` reports a generation in flight.
//  `applicationShouldTerminate(_:)` is the one AppKit hook that can defer that — return
//  `.terminateLater`, await the tracker draining (bounded, so a wedged generation can never make
//  the app unquittable), then reply.
//
import AppKit
import AriKitEngineMLX

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Upper bound on how long "Quit" waits for an in-flight MLX generation to finish before
    /// terminating anyway. A real summary's decode is bounded by `MLXClient.defaultMaxTokens`
    /// (4096) and comfortably finishes well under this; it exists only so a wedged/never-returning
    /// generation can't make the app impossible to quit.
    static let terminationDrainTimeout: Duration = .seconds(30)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await Self.awaitMLXIdle()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Awaits `MLXActivityTracker.shared.waitUntilIdle()` with a hard timeout — extracted as a
    /// `static` so it has no dependency on delegate/window state, for a focused unit test.
    static func awaitMLXIdle() async {
        if await MLXActivityTracker.shared.isIdle { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await MLXActivityTracker.shared.waitUntilIdle() }
            group.addTask { try? await Task.sleep(for: terminationDrainTimeout) }
            await group.next()
            group.cancelAll()
        }
    }
}
