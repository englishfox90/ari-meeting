//
//  StubServices.swift — honest placeholder `CaptureService`/`LiveTranscriptionService`
//  conformers (docs/plans/ari-recording-page.md §2.5, slice R2).
//
//  Used by `AppEnvironment` until R3–R6 land the real device-capture graph
//  (`MicrophoneCapture`/`SystemAudioTap`/`CaptureCoordinator` in `AriCapture`,
//  `LiveCaptureService`/`SpeechLiveTranscriptionService` app-side glue). No-Fake-State: capture
//  never claims to be ready here — `RecordingSession.confirmConsent()` always lands in `.failed`
//  with one of these exact, real reasons rather than a green `.recording` phase over a graph
//  that doesn't exist yet. The Record button on the idle screen stays disabled with the reason
//  visible (`RecordingView.canStartRecording`).
//
import AriKit
import AriViewModels
import Foundation

/// `start()` always throws — there is no device graph behind it yet. `sourceStatus()` reports
/// the same two honest reasons regardless of when it's called (before or after a failed
/// `start()`), so the idle screen's eager source-readiness probe and the post-start readout
/// agree.
struct StubCaptureService: CaptureService {
    static let microphoneUnavailableReason = "Microphone capture isn't built yet."
    static let systemAudioUnavailableReason = "System audio capture isn't built yet."

    func start() async throws {
        throw StubCaptureError.notImplemented
    }

    func finish() async throws -> URL {
        // Unreachable in practice — `RecordingSession` never reaches `.recording` (and therefore
        // never calls `finish()`) when `start()` always throws. Still an honest throw, not a
        // fabricated URL, if it were ever called directly.
        throw StubCaptureError.notImplemented
    }

    func mixedWindows() -> AsyncStream<PCMWindow> {
        AsyncStream { $0.finish() }
    }

    func liveLevel() -> AsyncStream<Float> {
        AsyncStream { $0.finish() }
    }

    func sourceStatus() async -> (mic: CaptureAvailability, system: CaptureAvailability) {
        (
            mic: .unavailable(reason: Self.microphoneUnavailableReason),
            system: .unavailable(reason: Self.systemAudioUnavailableReason)
        )
    }
}

enum StubCaptureError: Error, CustomStringConvertible, Sendable, Equatable {
    case notImplemented

    var description: String {
        "\(StubCaptureService.microphoneUnavailableReason) \(StubCaptureService.systemAudioUnavailableReason)"
    }
}

/// Reports the REAL on-device `SpeechTranscriber` engine/asset state via `SpeechAssetManager` —
/// that half is genuinely knowable headlessly today even though nothing is wired to feed it real
/// audio yet. `transcribe(windows:language:)` is never actually reachable in R2 (capture never
/// starts, so `RecordingSession` never calls it), but throws an honest error rather than
/// fabricating a result if it ever were.
struct StubLiveTranscriptionService: LiveTranscriptionService {
    let providerName = "speech-transcriber (capture not wired)"

    private let assetManager = SpeechAssetManager()

    func readiness() async -> TranscriberReadiness {
        guard assetManager.isEngineAvailable() else {
            return .unavailable(reason: "Live transcription arrives with the capture engine.")
        }

        let locale = STTLocale.resolveRequestedLocale(nil)
        guard await assetManager.areAssetsInstalled(forLocale: nil) else {
            return .unavailable(
                reason: "The on-device speech model for \(locale.identifier(.bcp47)) isn't installed yet."
            )
        }
        return .ready(locale: locale.identifier(.bcp47))
    }

    func transcribe(
        windows _: AsyncStream<PCMWindow>, language _: String?
    ) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: TranscriptionError.providerUnavailable(
                    "Live transcription arrives with the capture engine."
                )
            )
        }
    }
}
