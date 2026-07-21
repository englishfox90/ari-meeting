//
//  LiveTranscriptionService.swift — the STT seam protocol for `RecordingSession`
//  (docs/plans/ari-recording-page.md §2.4).
//
//  Abstracts live speech-to-text so `RecordingSession` never imports `Speech`/`AnalyzerInput` —
//  the `PCMWindow -> AnalyzerInput` conversion (`AnalyzerInputAdapter`, `AriKit/Engine/STT`) stays
//  entirely inside the real conformer (`SpeechLiveTranscriptionService`, the app-target R6 glue),
//  one layer downstream of this protocol.
//
import AriKit
import Foundation

/// Abstracts STT so `RecordingSession` never imports `Speech`.
public protocol LiveTranscriptionService: Sendable {
    /// A stable identifier for provenance — persisted as `Meeting.transcriptionProvider`.
    var providerName: String { get }

    /// Honest current readiness. Never fabricated: a real asset-download progress or a real
    /// unavailable reason, never silently reported as ready.
    func readiness() async -> TranscriberReadiness

    /// Consumes `windows` and yields finalized segments as they finalize. `language` is the
    /// optional locale hint (nil = the provider's default resolution).
    func transcribe(
        windows: AsyncStream<PCMWindow>, language: String?
    ) -> AsyncThrowingStream<TranscriptionSegment, Error>
}

/// Honest live-transcriber readiness (No-Fake-State: real `AssetInventory` progress, never an
/// invented percentage; a genuinely unusable engine reports why, never a silent green light).
public enum TranscriberReadiness: Sendable, Equatable {
    case ready(locale: String)
    case downloadingAssets(progress: Double)
    case unavailable(reason: String)
}
