//
//  SpeechTranscriberLiveStreamTests.swift — plan §6 Slice E, Lane 1 (headless, always runs).
//
//  Exercises `SpeechTranscriberProvider.transcribe(liveInputs:language:)`'s SHAPE + CANCELLATION
//  contract against a synthetic `AsyncStream<AnalyzerInput>` — never live mic capture (real mic
//  verification is Phase 3.2, TCC-gated). Two things are asserted headlessly, with no live-model
//  dependency:
//
//    1. Honest gating: an INJECTED-unavailable provider throws `.providerUnavailable` through the
//       returned stream and NEVER touches `liveInputs`/the analyzer — the exact
//       `TranscriptionErrorTests` seam pattern (`FoundationModelsClient`'s `unavailableReason`),
//       generalized to the live path. This needs no real `SpeechTranscriber`.
//
//    2. Cancellation/termination contract: feeding an intentionally OPEN-ENDED synthetic stream
//       (never finishes on its own — like a real mic stream that only ends when capture stops)
//       into the REAL `SpeechTranscriberProvider()` and cancelling the CONSUMER task must make the
//       returned `AsyncThrowingStream` terminate promptly via `onTermination` — proving the
//       structured `async let` drain + the internal-stream forwarding loop both respond to
//       cancellation instead of hanging. This is asserted regardless of whether a real
//       SpeechTranscriber model is available on this machine (per plan §6: "if a real model is
//       required to get any output, assert only the cancellation/termination contract and
//       honest-skip the content assertion") — any thrown error along the way must be an honest
//       `TranscriptionError`, never a hang and never fabricated segments.
//
import AVFoundation
import Foundation
import Speech
import Testing
@testable import AriKit

/// The exact format the real `en-US` `SpeechTranscriber` wants (← `SpeechAnalyzer
/// .bestAvailableAudioFormat(compatibleWith:)`, `Transcribe.swift:257`). Feeding a buffer in ANY
/// other format (e.g. the raw Float32/16kHz input contract, unconverted) has been observed to trap
/// deep inside the Speech framework's own recognizer worker rather than throwing a catchable Swift
/// error — so this test constructs its synthetic buffers directly in the analyzer's own preferred
/// format, exactly as `Transcribe.swift`'s `convertIfNeeded` does for the recorded-file/sidecar
/// path. `nil` when the engine reports no preference (falls back to a plain 16kHz mono format);
/// `nil` when the engine is genuinely unavailable on this machine (honest — no fabricated format).
private func liveInputFormat() async -> AVAudioFormat {
    guard SpeechTranscriber.isAvailable,
          let target = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    else {
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }
    let probeTranscriber = SpeechTranscriber(
        locale: target,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange, .transcriptionConfidence]
    )
    return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probeTranscriber])
        ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
}

/// Builds one small silent `AnalyzerInput` buffer — no real speech content, just a validly-shaped
/// PCM buffer in the analyzer's own preferred format so the analyzer has something to chew on
/// without tripping an internal format precondition. Mirrors `Transcribe.swift`'s
/// `makeInputBuffer(from:)`, simplified to always-silent samples (content doesn't matter for a
/// shape/cancellation test — only that the buffer is well-formed and correctly formatted).
private func makeSilentAnalyzerInput(format: AVAudioFormat, durationSec: Double = 0.5) throws -> AnalyzerInput {
    let frameCount = AVAudioFrameCount(format.sampleRate * durationSec)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw TranscriptionError.audioDecodeFailed("failed to allocate test audio buffer")
    }
    buffer.frameLength = frameCount // zeroed (silent) by default allocation
    return AnalyzerInput(buffer: buffer)
}

struct SpeechTranscriberLiveStreamTests {

    // MARK: - 1. Honest gating (headless, no real SpeechTranscriber needed)

    @Test func unavailableEngineThrowsProviderUnavailableAndNeverConsumesLiveInputs() async throws {
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        // An open-ended synthetic stream — if the gating check were skipped, the provider would
        // hang forever forwarding from it. It should never even be iterated.
        defer { inputContinuation.finish() }

        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { false },
            supportedLocale: { _ in
                Issue.record("supportedLocale must never be consulted when the engine is unavailable")
                return nil
            },
            installedLocalesCheck: {
                Issue.record("installedLocales must never be consulted when the engine is unavailable")
                return []
            }
        )

        let resultStream = provider.transcribe(liveInputs: inputSequence, language: "en-US")

        do {
            for try await segment in resultStream {
                Issue.record("expected no segments before the honest gating error; got \(segment)")
            }
            Issue.record("expected .providerUnavailable")
        } catch TranscriptionError.providerUnavailable {
            // expected — no fabricated segments, no attempt to consult locale/asset seams.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func unsupportedLocaleThrowsUnsupportedLanguageOverLiveStream() async throws {
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        defer { inputContinuation.finish() }

        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in nil },
            installedLocalesCheck: {
                Issue.record("installedLocales must never be consulted once the locale is unsupported")
                return []
            }
        )

        let resultStream = provider.transcribe(liveInputs: inputSequence, language: "zz-ZZ")

        do {
            for try await segment in resultStream {
                Issue.record("expected no segments before the honest gating error; got \(segment)")
            }
            Issue.record("expected .unsupportedLanguage")
        } catch let TranscriptionError.unsupportedLanguage(identifier) {
            #expect(identifier.lowercased().contains("zz"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - 2. Cancellation / termination contract (real provider, synthetic open-ended input)

    @Test func liveStreamTerminatesPromptlyWhenTheConsumerCancels() async throws {
        let provider = SpeechTranscriberProvider()
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Feed one buffer so there is at least something for a real analyzer to have started
        // working on, then deliberately DO NOT finish the sequence — this mirrors a real mic
        // stream that only ends when capture stops, and is exactly the shape that would hang
        // forever if cancellation weren't wired correctly.
        let format = await liveInputFormat()
        try inputContinuation.yield(makeSilentAnalyzerInput(format: format))

        let resultStream = provider.transcribe(liveInputs: inputSequence, language: "en-US")

        let consumer = Task {
            var segmentCount = 0
            for try await _ in resultStream {
                segmentCount += 1
            }
            return segmentCount
        }

        // Give the pipeline a brief moment to actually start (gating + analyzer session start),
        // then cancel the CONSUMER — this is what drives `AsyncThrowingStream.onTermination`,
        // which must cancel the provider's internal task rather than leaking a hung forward loop.
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        inputContinuation.finish()

        // The consumer task itself must settle promptly once cancelled — proving `onTermination`
        // actually propagated cancellation into the provider's structured work instead of hanging.
        // Content is NOT asserted here (plan §6): whether any segments were produced depends on
        // whether this machine has a real, asset-installed SpeechTranscriber — only the
        // termination/cancellation contract is load-bearing for Slice E.
        switch await consumer.result {
        case .success:
            break // drained cleanly (with or without segments) before/at cancellation — fine.
        case let .failure(error):
            if error is CancellationError {
                break // expected — cooperative cancellation.
            }
            // Any other error must be an honest No-Fake-State failure (e.g. engine/assets
            // unavailable on this machine), never a hang and never a fabricated segment.
            #expect(error is TranscriptionError, "unexpected non-honest error: \(error)")
        }
    }

    @Test func liveStreamFinishesWhenTheCallerSequenceEndsNaturally() async throws {
        // A FINITE synthetic stream (unlike the open-ended one above): feeds a couple of silent
        // buffers and finishes on its own, proving the forward-then-finalize path terminates the
        // returned stream without needing external cancellation at all.
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let format = await liveInputFormat()
        try inputContinuation.yield(makeSilentAnalyzerInput(format: format))
        try inputContinuation.yield(makeSilentAnalyzerInput(format: format))
        inputContinuation.finish()

        let provider = SpeechTranscriberProvider()
        let resultStream = provider.transcribe(liveInputs: inputSequence, language: "en-US")

        // Bound the wait so a regression that hangs fails the test instead of the suite itself
        // hanging forever.
        let drain = Task {
            var segments: [TranscriptionSegment] = []
            do {
                for try await segment in resultStream {
                    segments.append(segment)
                }
                return Result<[TranscriptionSegment], Error>.success(segments)
            } catch {
                return Result<[TranscriptionSegment], Error>.failure(error)
            }
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            drain.cancel()
        }

        let outcome = await drain.value
        timeout.cancel()

        switch outcome {
        case .success:
            break // stream finished on its own once the finite input sequence was exhausted.
        case let .failure(error):
            // An honest engine/asset-unavailability error is acceptable on a bare machine; a hang
            // (caught by the 30s timeout cancelling `drain`, which surfaces as CancellationError)
            // is not.
            #expect(error is TranscriptionError, "unexpected error (or timeout/hang): \(error)")
        }
    }
}
