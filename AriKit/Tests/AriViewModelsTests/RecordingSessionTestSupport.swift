//
//  RecordingSessionTestSupport.swift — spy `CaptureService` + stub `LiveTranscriptionService`
//  test doubles for `RecordingSessionTests` (docs/plans/ari-recording-page.md §6 Lane 1).
//
import AriKit
@testable import AriViewModels
import Foundation

/// A `CaptureService` spy: an actor so its call counters/config are safely mutable across the
/// async boundary, while `mixedWindows()`/`liveLevel()` (non-async protocol requirements) are
/// `nonisolated` over immutable, `Sendable` `AsyncStream`s created at `init` — the same shape a
/// real actor-isolated conformer (`CaptureCoordinator`) needs to satisfy those requirements.
actor SpyCaptureService: CaptureService {
    private(set) var startCallCount = 0
    private(set) var finishCallCount = 0

    var startError: Error?
    var finishResult: Result<URL, Error> = .success(URL(fileURLWithPath: "/tmp/spy-recording.m4a"))
    var mic: CaptureAvailability = .ready
    var system: CaptureAvailability = .ready

    nonisolated let windowsStream: AsyncStream<PCMWindow>
    private let windowsContinuation: AsyncStream<PCMWindow>.Continuation
    nonisolated let levelStream: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation

    init() {
        let (windows, windowsContinuation) = AsyncStream<PCMWindow>.makeStream()
        windowsStream = windows
        self.windowsContinuation = windowsContinuation
        let (level, levelContinuation) = AsyncStream<Float>.makeStream()
        levelStream = level
        self.levelContinuation = levelContinuation
    }

    func configureStart(error: Error?) {
        startError = error
    }

    func configureFinish(_ result: Result<URL, Error>) {
        finishResult = result
    }

    func configureSourceStatus(mic: CaptureAvailability, system: CaptureAvailability) {
        self.mic = mic
        self.system = system
    }

    func yield(_ window: PCMWindow) {
        windowsContinuation.yield(window)
    }

    func yield(level: Float) {
        levelContinuation.yield(level)
    }

    func start() async throws {
        startCallCount += 1
        if let startError {
            throw startError
        }
    }

    func finish() async throws -> URL {
        finishCallCount += 1
        windowsContinuation.finish()
        levelContinuation.finish()
        switch finishResult {
        case let .success(url):
            return url
        case let .failure(error):
            throw error
        }
    }

    nonisolated func mixedWindows() -> AsyncStream<PCMWindow> {
        windowsStream
    }

    nonisolated func liveLevel() -> AsyncStream<Float> {
        levelStream
    }

    func sourceStatus() async -> (mic: CaptureAvailability, system: CaptureAvailability) {
        (mic, system)
    }
}

/// A generic `Error` for spy-configured failures — `Sendable`/`Equatable` so tests can assert on
/// the resulting `.failed(String)` message without depending on `NSError` formatting.
struct SpyError: Error, Sendable, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// A `LiveTranscriptionService` stub. A `Sendable` value type (mirrors `StubTranscriptionProvider`)
/// whose segment emission is fully caller-controlled via `makeStream` — so tests can either emit a
/// fixed canned batch immediately, or hold a continuation open to model "a segment is still in
/// flight" at `stop()`.
struct StubLiveTranscriptionService: LiveTranscriptionService {
    let providerName: String
    let readinessValue: TranscriberReadiness
    let makeStream: @Sendable () -> AsyncThrowingStream<TranscriptionSegment, Error>

    init(
        providerName: String = "stub-live",
        readiness: TranscriberReadiness = .ready(locale: "en-US"),
        makeStream: @escaping @Sendable () -> AsyncThrowingStream<TranscriptionSegment, Error>
    ) {
        self.providerName = providerName
        readinessValue = readiness
        self.makeStream = makeStream
    }

    /// Convenience: yields `cannedSegments` immediately, in order, then finishes (or throws
    /// `error` after them, if given).
    init(
        providerName: String = "stub-live",
        readiness: TranscriberReadiness = .ready(locale: "en-US"),
        cannedSegments: [TranscriptionSegment],
        error: (any Error & Sendable)? = nil
    ) {
        self.init(providerName: providerName, readiness: readiness) {
            AsyncThrowingStream { continuation in
                for segment in cannedSegments {
                    continuation.yield(segment)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    func readiness() async -> TranscriberReadiness {
        readinessValue
    }

    func transcribe(
        windows _: AsyncStream<PCMWindow>, language _: String?
    ) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        makeStream()
    }
}
