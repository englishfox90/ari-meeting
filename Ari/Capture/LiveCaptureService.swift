//
//  LiveCaptureService.swift — the real `CaptureService` conformer (plan §2.5, slice R5):
//  thin app-side glue wiring `CaptureCoordinator` + `MicrophoneCapture` + `SystemAudioTap`
//  (all the actual capture logic lives in `AriCapture`; this file only composes it).
//
//  One instance per recording attempt — `RecordingSession` calls `makeCaptureService(folder)`
//  fresh each time it starts, so the coordinator's one-shot start/finish lifecycle maps 1:1.
//
import AriCapture
import AriKit
import AriViewModels
import Foundation

struct LiveCaptureService: CaptureService {
    private let coordinator: CaptureCoordinator

    /// Pre-start readiness for the idle screen's eager probe: both sources can answer before a
    /// start attempt — the mic from real TCC state, the system tap by pre-flighting the Screen &
    /// System-Audio Recording grant (`SystemAudioTap.availability()`).
    private let microphone: MicrophoneCapture
    private let systemTap: SystemAudioTap

    /// The persisted microphone device UID to prefer, read once at `start()`
    /// (docs/plans/settings-audio-devices.md §2.3). Defaults to `{ nil }` for the source-probe
    /// path (`AppEnvironment`'s eager `sourceStatus()` construction), which never calls `start()`.
    private let preferredMicDeviceUID: @Sendable () async -> String?

    init(
        meetingFolder: URL,
        preferredMicDeviceUID: @escaping @Sendable () async -> String? = { nil }
    ) {
        let microphone = MicrophoneCapture()
        let systemTap = SystemAudioTap()
        self.microphone = microphone
        self.systemTap = systemTap
        self.preferredMicDeviceUID = preferredMicDeviceUID
        coordinator = CaptureCoordinator(
            config: CaptureCoordinator.Config(meetingFolder: meetingFolder),
            microphone: microphone,
            systemTap: systemTap
        )
    }

    func start() async throws {
        // Applied before the coordinator starts the same actor's `installTapAndStart` path, so
        // the very first tap already binds to the chosen device (settings-audio-devices.md §2.3).
        await microphone.setPreferredDeviceUID(preferredMicDeviceUID())
        try await coordinator.start()
    }

    func finish() async throws -> URL {
        try await coordinator.finish()
    }

    func mixedWindows() -> AsyncStream<PCMWindow> {
        // The coordinator is an actor; hop through an unfolding stream so the protocol's
        // synchronous shape is preserved without blocking.
        bridge { await coordinator.mixedWindows() }
    }

    func liveLevel() -> AsyncStream<Float> {
        bridge { await coordinator.liveLevel() }
    }

    func sourceStatus() async -> (mic: CaptureAvailability, system: CaptureAvailability) {
        let status = await coordinator.sourceStatus()
        // Before start() the coordinator reports .notDetermined for both; each source can do
        // better than that placeholder via its own pre-flight (real mic TCC state, and the
        // system tap's Screen-Recording grant probe), so substitute those while nothing has
        // started. Once a start has run, the coordinator's recorded status is authoritative.
        var resolved = status
        if case .notDetermined = status.mic {
            resolved.mic = await microphone.availability()
        }
        if case .notDetermined = status.system {
            resolved.system = await systemTap.availability()
        }
        return resolved
    }

    /// Bridges an actor-isolated `AsyncStream` accessor into the protocol's synchronous
    /// return shape: subscribe inside a task, forward every element. The outer stream keeps
    /// the coordinator's drop-oldest posture (review finding H2) — an unbounded re-buffer here
    /// would silently defeat backpressure and grow without bound under a slow STT consumer.
    private func bridge<Element: Sendable>(
        _ subscribe: @escaping @Sendable () async -> AsyncStream<Element>
    ) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task {
                for await element in await subscribe() {
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
