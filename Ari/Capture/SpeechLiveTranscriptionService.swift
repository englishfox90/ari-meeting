//
//  SpeechLiveTranscriptionService.swift — the real `LiveTranscriptionService` conformer
//  (plan §2.5, slice R6): composes `AnalyzerInputAdapter` + `SpeechTranscriberProvider`'s
//  live path + `SpeechAssetManager`.
//
//  `readiness()` is make-ready-if-possible, honestly reported: engine unavailable → the real
//  reason; assets missing → a REAL `AssetInventory` install runs to completion before `.ready`
//  is claimed (never "ready" over a missing model). While a first-run install is in flight the
//  session shows its own in-progress copy; per-fraction progressive readiness is the R9-era
//  refinement (plan §9-1), not faked here.
//
import AriKit
import AriViewModels
import Foundation
import os

struct SpeechLiveTranscriptionService: LiveTranscriptionService {
    private static let logger = Logger(subsystem: "com.arivo.ari", category: "capture.stt")

    let providerName = "speech-transcriber"

    private let provider = SpeechTranscriberProvider()
    private let assetManager = SpeechAssetManager()

    func readiness() async -> TranscriberReadiness {
        guard assetManager.isEngineAvailable() else {
            return .unavailable(reason: "On-device transcription isn't available on this Mac.")
        }

        let locale = STTLocale.resolveRequestedLocale(nil)
        if await assetManager.areAssetsInstalled(forLocale: nil) {
            return .ready(locale: locale.identifier(.bcp47))
        }

        // First run: download the on-device speech model now (OS-managed, one-time). The
        // returned state is terminal-honest — `.ready` only after the manager's own
        // post-install verification.
        do {
            try await assetManager.install(forLocale: nil) { fraction in
                Self.logger.info("Speech model download progress: \(fraction, format: .fixed(precision: 2))")
            }
            return .ready(locale: locale.identifier(.bcp47))
        } catch {
            return .unavailable(
                reason: "The on-device speech model for \(locale.identifier(.bcp47)) could not be installed: \(error)"
            )
        }
    }

    func transcribe(
        windows: AsyncStream<PCMWindow>, language: String?
    ) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        provider.transcribe(
            liveInputs: AnalyzerInputAdapter.analyzerInputs(from: windows),
            language: language
        )
    }
}
