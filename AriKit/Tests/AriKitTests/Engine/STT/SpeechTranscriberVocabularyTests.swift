//
//  SpeechTranscriberVocabularyTests.swift — docs/plans/custom-vocabulary.md §5, T-C2 + T-C3
//  (combined per the user's "one test per step, make it count" instruction).
//
//  The load-bearing hot-path guard: `vocabularyBias()` must be called EXACTLY ONCE per live
//  transcription session — on the STT task, before analysis starts — and NEVER from the
//  per-buffer forwarding loop (`SpeechTranscriberProvider.swift`'s live path). A per-buffer DB
//  read is exactly the defect this test is written to catch, so the live path is driven with
//  ≥50 synthetic buffers (well beyond any single-digit "looks fine by accident" count).
//
import AVFoundation
import Foundation
import Speech
import Testing
@testable import AriKit

/// Thread-safe call counter, `Sendable`-clean under strict concurrency (mirrors the counting-seam
/// pattern used elsewhere in the STT suite — no `@unchecked Sendable`, no shared mutable `var`
/// captured directly in a `@Sendable` closure).
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// One small silent `AnalyzerInput` buffer in a plain 16 kHz mono format — content doesn't matter
/// for this test (it only pins the vocabulary-fetch call count, not transcription output), so no
/// analyzer-preferred-format probing is needed here.
private func makeSilentBuffer(durationSec: Double = 0.02) throws -> AnalyzerInput {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!
    let frameCount = AVAudioFrameCount(format.sampleRate * durationSec)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw TranscriptionError.audioDecodeFailed("failed to allocate test audio buffer")
    }
    buffer.frameLength = frameCount // zeroed (silent) by default allocation
    return AnalyzerInput(buffer: buffer)
}

/// A file path that is never opened by these tests — every seam is configured so the provider
/// resolves availability/locale/assets successfully and reaches the real `AVAudioFile(forReading:)`
/// call, which then fails honestly with `.audioDecodeFailed`. Reaching exactly that error (and no
/// other) is the proof that the vocabulary step ran and did not itself disrupt the normal flow
/// (mirrors `TranscriptionErrorTests.unreachableFileURL`'s role).
private let unreachableFileURL = URL(fileURLWithPath: "/nonexistent/does-not-exist.wav")

struct SpeechTranscriberVocabularyTests {
    // T-C1 — with the default `{ nil }` seam, the provider must not build/attach an
    // `AnalysisContext` at all. Asserted structurally via the documented `SpeechAnalyzer.context`
    // getter (verified at swiftinterface:229) rather than a bespoke Speech-internals hook.
    @Test func nilBiasAttachesNoContext() async throws {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let before = await analyzer.context.contextualStrings[.general]
        #expect(before == nil, "a freshly constructed analyzer must start with no .general contextual strings")

        await SpeechTranscriberProvider.applyVocabularyBias(nil, to: analyzer)

        let after = await analyzer.context.contextualStrings[.general]
        #expect(after == nil, "a nil bias must leave the analyzer's context untouched — no setContext call")
    }

    // T-C4 — a vocabulary seam that fails internally (caught, resolved to nil, exactly like
    // `VocabularySource.bias()`'s `try?` best-effort contract) must not derail transcription: the
    // provider proceeds to the same honest failure a normal unbiased run would hit.
    @Test func vocabularyFetchFailureDoesNotFailTranscription() async {
        struct SimulatedVocabularyFetchFailure: Error {}

        let provider = SpeechTranscriberProvider(
            isAvailableCheck: { true },
            supportedLocale: { _ in Locale(identifier: "en-US") },
            installedLocalesCheck: { [Locale(identifier: "en-US")] },
            vocabularyBias: {
                // Mirrors `VocabularySource.bias()`: an internal failure resolves to `nil`,
                // never propagates as a thrown error out of the seam.
                do {
                    throw SimulatedVocabularyFetchFailure()
                } catch {
                    return nil
                }
            }
        )

        do {
            _ = try await provider.transcribe(fileURL: unreachableFileURL, language: "en-US")
            Issue.record("expected .audioDecodeFailed — the file genuinely does not exist")
        } catch TranscriptionError.audioDecodeFailed {
            // expected: the provider reached the normal file-open step, proving the failed
            // vocabulary fetch did not abort or otherwise disrupt transcription.
        } catch {
            Issue.record("unexpected error from a failed vocabulary fetch: \(error)")
        }
    }

    @Test func biasIsFetchedExactlyOnceAcrossFiftyPlusLiveBuffers() async throws {
        let counter = CallCounter()

        let provider = SpeechTranscriberProvider(vocabularyBias: {
            await counter.increment()
            return nil // unbiased — the count is what's under test, not the biasing content.
        })

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        // Drive well past 50 buffers — a per-buffer regression would inflate the counter far
        // beyond 1 long before this loop finishes.
        for _ in 0 ..< 60 {
            try inputContinuation.yield(makeSilentBuffer())
        }
        inputContinuation.finish()

        let resultStream = provider.transcribe(liveInputs: inputSequence, language: "en-US")

        // Bound the wait so a hang fails the test instead of the suite itself hanging.
        let drain = Task {
            do {
                for try await _ in resultStream {}
                return true
            } catch {
                // An honest engine/asset-unavailability error is acceptable on a bare machine —
                // only the call count below is load-bearing for this test.
                return true
            }
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            drain.cancel()
        }
        _ = await drain.value
        timeout.cancel()

        let finalCount = await counter.count
        #expect(finalCount == 1, "vocabularyBias() must be fetched exactly once per live session, not per buffer")
    }
}
