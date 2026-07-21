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

    /// Pre-start readiness for the idle screen's eager probe: real TCC state for the mic;
    /// the system tap has no pre-flight query (TCC fires on first tap creation), so
    /// `.notDetermined` is the only honest static answer before a start attempt.
    private let microphone: MicrophoneCapture

    init(meetingFolder: URL) {
        let microphone = MicrophoneCapture()
        let systemTap = SystemAudioTap()
        self.microphone = microphone
        coordinator = CaptureCoordinator(
            config: CaptureCoordinator.Config(meetingFolder: meetingFolder),
            microphone: microphone,
            systemTap: systemTap
        )
    }

    func start() async throws {
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
        // Before start() the coordinator reports .notDetermined for both; the mic can do
        // better (real TCC state), so prefer its answer while nothing has started.
        if case .notDetermined = status.mic {
            return await (microphone.availability(), status.system)
        }
        return status
    }

    /// Bridges an actor-isolated `AsyncStream` accessor into the protocol's synchronous
    /// return shape: subscribe inside a task, forward every element.
    private func bridge<Element: Sendable>(
        _ subscribe: @escaping @Sendable () async -> AsyncStream<Element>
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
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
