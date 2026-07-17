//
//  main.swift
//  ari-notch
//
//  Entry point for the Ari Notch sidecar.
//
//  Lifecycle:
//    1. Start a background thread reading stdin line-by-line (NDJSON).
//    2. Decode each line into `NotchInbound`; hop to the main actor and fold it
//       into the shared `NotchModel`.
//    3. Detect notch-vs-capsule and emit `{"type":"ready","has_notch":<bool>}`.
//    4. Drive our CUSTOM simulated Dynamic Island (`IslandPanelController`) —
//       a borderless NSPanel hosting the island chrome + reused content views.
//       (WS-H: DynamicNotchKit was dropped; see IslandPanelController.swift.)
//    5. Write outbound `NotchOutbound` JSON lines to stdout, line-buffered.
//
//  We must NOT block the AppKit main run loop on stdin, hence the dedicated
//  reader thread. The reader owns no UI; it only forwards decoded messages onto
//  the main actor (preserving FIFO order via the main dispatch queue).
//

import AppKit
import SwiftUI

// MARK: - Outbound writer (thread-safe, line-buffered, flushed)

/// Serializes and writes `NotchOutbound` messages to stdout as NDJSON. All
/// writes go through one lock so interleaved threads never corrupt a line.
enum NotchIO {
    private static let lock = NSLock()

    static func send(_ message: NotchOutbound) {
        // A fresh encoder per call keeps this free of shared non-Sendable state.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(message),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(line.utf8))
        // Flush the C stdio layer too, in case anything downstream shares fd 1.
        fflush(stdout)
    }

    /// Convenience: emit a structured log line up to the Rust logger.
    static func log(_ level: String, _ message: String) {
        send(.log(level: level, message: message))
    }
}

// MARK: - Action emitter (real, stdout-backed)

/// Production `NotchActionEmitter`: wraps a HUD action in `NotchOutbound.action`
/// and writes it as one NDJSON line via `NotchIO`. The HUD depends only on the
/// protocol, so tests substitute a capturing mock.
struct StdoutActionEmitter: NotchActionEmitter {
    func emit(_ action: NotchAction) {
        NotchIO.send(.action(action))
    }
}

// NOTE: `NotchRootView` (the content router) now lives in NotchRootView.swift —
// logic unchanged, just relocated for WS-H clarity.

// MARK: - Stdin reader thread

/// Reads NDJSON from stdin on a background thread and applies each decoded
/// message to the model on the main actor.
final class StdinReader {
    private let model: NotchModel
    private var thread: Thread?

    init(model: NotchModel) {
        self.model = model
    }

    func start() {
        let model = self.model
        let t = Thread {
            let decoder = JSONDecoder()
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let data = trimmed.data(using: .utf8) else { continue }

                let message: NotchInbound
                do {
                    message = try decoder.decode(NotchInbound.self, from: data)
                } catch {
                    // Malformed line: log and keep going, never crash the reader.
                    NotchIO.log("warn", "failed to decode inbound line: \(error)")
                    continue
                }

                // Apply on the main actor, preserving arrival order (FIFO queue).
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let keepRunning = model.apply(message)
                        if !keepRunning {
                            // `.shutdown` received — exit cleanly.
                            NotchIO.log("info", "shutdown requested; exiting")
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
            }
            // EOF on stdin (parent closed the pipe): treat as shutdown.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        t.name = "ari-notch.stdin-reader"
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }
}

// MARK: - Notch detection

/// True when the PRIMARY display (the one designated "main" in System Settings,
/// always at global origin (0,0)) has a physical notch — a non-zero top safe-area
/// inset. This is only the value reported in the `ready` message; the island host
/// pins to that same primary display and simulates a pill on non-notched displays,
/// so the sidecar renders correctly either way.
@MainActor
func detectHasNotch() -> Bool {
    let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    return (primary?.safeAreaInsets.top ?? 0) > 0
}

// MARK: - Bootstrap
//
// Top-level code in an executable's `main.swift` runs on the main thread, so we
// assert main-actor isolation to construct the (@MainActor) model + AppKit host.

MainActor.assumeIsolated {
    let model = NotchModel()

    // Start reading stdin immediately so we don't miss early messages while the
    // UI spins up. Decoded messages queue onto the main actor in arrival order.
    let reader = StdinReader(model: model)
    reader.start()

    let app = NSApplication.shared
    // Accessory: no Dock icon, no menu bar — this is a headless panel host.
    app.setActivationPolicy(.accessory)

    // Build the custom island host now (retained for the app's lifetime by this
    // scope, which blocks on `app.run()` below). The controller owns the
    // borderless NSPanel + SwiftUI chrome; `NotchRootView` routes HUD vs alert.
    let emitter = StdoutActionEmitter()
    let controller = IslandPanelController(model: model, emitter: emitter)

    // Once the run loop is live, announce readiness and bring up the island.
    Task { @MainActor in
        let hasNotch = detectHasNotch()
        NotchIO.send(.ready(hasNotch: hasNotch))
        NotchIO.log("info", "ari-notch ready (has_notch=\(hasNotch))")

        // Show top-center of the active screen and start following screen /
        // active-app changes. `orderFrontRegardless()` inside — never steals focus.
        controller.show()
    }

    app.run()
    // Keep `controller` alive across the (blocking) run loop.
    _ = controller
}
