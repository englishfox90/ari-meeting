//
//  CaptureService.swift — the capture-graph seam protocol for `RecordingSession`
//  (docs/plans/ari-recording-page.md §2.4).
//
//  Abstracts the real device-capture graph (`AriCapture`'s future `CaptureCoordinator` +
//  `MicrophoneCapture` + `SystemAudioTap`, wired app-side by `LiveCaptureService`, R3-R5) so
//  `RecordingSession` tests headlessly and never imports `AriCapture` — plan §2's explicit rule
//  ("`AriViewModels` gains no `AriCapture` dependency"). This also keeps the module iOS-clean:
//  Phase 6's "Ari Lite" supplies its own mic-only conformer without pulling in macOS-only capture.
//
import AriKit
import Foundation

/// Abstracts the capture graph so `RecordingSession` tests headlessly and never imports
/// `AriCapture`.
public protocol CaptureService: Sendable {
    /// Starts the underlying devices. Throws honestly if NEITHER source starts (mirrors
    /// `CaptureCoordinator.start()`'s contract) — never a green `.recording` phase over a dead
    /// graph.
    func start() async throws

    /// Stops devices, flushes/remuxes, and returns the final `.m4a` URL.
    func finish() async throws -> URL

    /// Mixed 48 kHz mono windows for STT.
    func mixedWindows() -> AsyncStream<PCMWindow>

    /// Peak-hold live level for the meter/HUD.
    func liveLevel() -> AsyncStream<Float>

    /// Honest per-source status, read after `start()` to decide what to surface (e.g. the
    /// "System audio unavailable — recording microphone only." banner).
    func sourceStatus() async -> (mic: CaptureAvailability, system: CaptureAvailability)
}
