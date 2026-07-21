//
//  CaptureAvailability.swift — honest per-source capture readiness
//  (docs/plans/ari-recording-page.md §2.1/§2.4).
//
//  ⚠️ Plan deviation (noted per the R1 task brief): the plan's §2.1 code block sketches this type
//  living in `AriCapture` (alongside `MicrophoneCapture`/`SystemAudioTap`). It is defined here in
//  `AriKit` instead — the same home as the sibling seam type `PCMWindow`
//  (`AriKit/Sources/AriKit/Capture/PCMWindow.swift`) — because plan §2 is explicit that
//  `AriViewModels` gains **no** `AriCapture` dependency (`RecordingSession`'s `CaptureService`
//  protocol, which exposes `sourceStatus() -> (mic: CaptureAvailability, system:
//  CaptureAvailability)`, lives in `AriViewModels`). Placing the type in `AriCapture` would force
//  either a forbidden `AriViewModels -> AriCapture` dependency or a duplicate type in two modules.
//  `AriKit` is the one module every consumer (`AriCapture`, `AriViewModels`, the `Ari` app target)
//  already depends on, so it is the correct shared home — mirrors why `PCMWindow` itself lives
//  here and not in `AriCapture`.
//
//  Honest tri-state readiness (No-Fake-State): `.unavailable(reason:)` always carries the real
//  reason a source can't be used (TCC denial, no device, tap creation failure) — never a silent
//  green light over a source that produces no signal.
//

/// Whether a capture source (microphone / system audio) can actually be used right now.
public enum CaptureAvailability: Sendable, Equatable {
    case ready
    /// The TCC prompt has not yet been resolved; requesting `start()` will trigger it.
    case notDetermined
    /// Denied / no device / tap creation failed — the real reason, never fabricated.
    case unavailable(reason: String)
}
