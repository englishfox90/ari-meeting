//
//  SpeechTranscriberProvider.swift — the SpeechAnalyzer/SpeechTranscriber conformer,
//  RECORDED-FILE path (plan §2.3, Slice C). The live-stream path is Slice E.
//
//  Absorbs the S2 spike's whole-file driver (`Entry.swift`) + apple-helper's in-process usage
//  (`Transcribe.swift`) into a product `TranscriptionProvider` conformer. Symbols reused verbatim
//  from the verified macOS-26-SDK swiftinterface (`Transcribe.swift:17-37`,
//  `EnsureAssets.swift:19-30`) — not re-derived:
//    - `SpeechTranscriber.isAvailable` / `.installedLocales` / `.supportedLocale(equivalentTo:)`
//    - `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` with
//      `[.audioTimeRange, .transcriptionConfidence]` (Entry.swift:163-168)
//    - `SpeechAnalyzer(modules:)` + `analyzer.analyzeSequence(from: AVAudioFile)` →
//      `finalizeAndFinish(through:)` / `cancelAndFinishNow()` (Entry.swift:244-249)
//    - The Sendable-clean results-drain pattern: a child `Task` that RETURNS its collected value,
//      no mutable outer capture (Entry.swift:194-217)
//
//  No-Fake-State (plan §7): every failure path (engine unavailable, locale unsupported, assets not
//  installed, file open failure, analyzer/results failure, cancellation) THROWS a descriptive
//  `TranscriptionError` — never fabricates text or a confidence value. Empty finalized text for
//  genuine silence is returned verbatim (Transcribe.swift:185-188).
//
//  Availability/locale-resolution are injectable seams (mirrors `FoundationModelsClient`'s
//  `unavailableReason`/`respond` pattern, `FoundationModelsClient.swift:42-58`) so the error-path
//  tests run headlessly, without a real `SpeechTranscriber`/device-asset dependency. Production
//  code (`init()`) always wires the real framework calls.
//
import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

public struct SpeechTranscriberProvider: TranscriptionProvider, Sendable {
    private static let logger = Logger(subsystem: "com.arivo.ari.AriKit", category: "stt.vocabulary")

    public let providerName: String = "speechanalyzer"

    /// Injectable engine-availability probe (← `SpeechTranscriber.isAvailable`, `Transcribe.swift
    /// :84`), decoupled from the live static so error-path tests can force the unavailable path
    /// headlessly, without requiring a real SpeechTranscriber-capable machine.
    let isAvailableCheck: @Sendable () -> Bool

    /// Injectable locale-resolution seam (← `SpeechTranscriber.supportedLocale(equivalentTo:)`,
    /// `Transcribe.swift:104`). Returns `nil` when the engine has no supported equivalent locale.
    let supportedLocale: @Sendable (Locale) async -> Locale?

    /// Injectable installed-locales seam (← `SpeechTranscriber.installedLocales`,
    /// `Transcribe.swift:107`).
    let installedLocalesCheck: @Sendable () async -> [Locale]

    /// Injectable custom-vocabulary seam (docs/plans/custom-vocabulary.md §2.4/§3). Mirrors
    /// `isAvailableCheck` / `supportedLocale` / `installedLocalesCheck`: `nil` means no biasing at
    /// all. Defaulted to `{ nil }` so every existing construction site and test keeps today's
    /// exact (unbiased) behavior. Called EXACTLY ONCE per transcription, before analysis starts —
    /// never from the per-buffer live forwarding loop (see `transcribe(liveInputs:language:)`).
    let vocabularyBias: @Sendable () async -> VocabularyBias?

    public init(vocabularyBias: @escaping @Sendable () async -> VocabularyBias? = { nil }) {
        isAvailableCheck = { SpeechTranscriber.isAvailable }
        supportedLocale = { locale in await SpeechTranscriber.supportedLocale(equivalentTo: locale) }
        installedLocalesCheck = { await SpeechTranscriber.installedLocales }
        self.vocabularyBias = vocabularyBias
    }

    /// Test-only initializer with injected seams — mirrors `FoundationModelsClient`'s
    /// `unavailableReason:`/`respond:` pattern so `TranscriptionErrorTests` can force the
    /// unavailable/unsupported/assets-missing paths headlessly. `vocabularyBias` defaults to
    /// `{ nil }` so existing call sites (`TranscriptionErrorTests`, etc.) are unaffected.
    init(
        isAvailableCheck: @escaping @Sendable () -> Bool,
        supportedLocale: @escaping @Sendable (Locale) async -> Locale?,
        installedLocalesCheck: @escaping @Sendable () async -> [Locale],
        vocabularyBias: @escaping @Sendable () async -> VocabularyBias? = { nil }
    ) {
        self.isAvailableCheck = isAvailableCheck
        self.supportedLocale = supportedLocale
        self.installedLocalesCheck = installedLocalesCheck
        self.vocabularyBias = vocabularyBias
    }

    /// Builds a FRESH `AnalysisContext` per transcription call from `bias` and applies it to
    /// `analyzer` via `setContext(_:)`. Never stores or shares the context (§3: `AnalysisContext`
    /// is a reference type; a fresh instance per call sidesteps relying on its internal
    /// synchronization). A `nil` bias attaches no context at all. A `setContext` failure is logged
    /// and swallowed — a meeting must never fail to transcribe because a glossary could not be
    /// attached (§3 "Failure policy for setContext").
    ///
    /// Deliberately not `private`: this is the "spy seam" T-C1 (docs/plans/custom-vocabulary.md
    /// §5) uses to assert structurally, via `SpeechAnalyzer.context` (the documented framework
    /// getter), that a `nil` bias leaves the analyzer's context untouched — no bespoke test hook
    /// reaching into Speech internals.
    static func applyVocabularyBias(_ bias: VocabularyBias?, to analyzer: SpeechAnalyzer) async {
        guard let bias else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = bias.contextualStrings
        do {
            try await analyzer.setContext(context)
        } catch {
            logger.error(
                "setContext failed, proceeding unbiased: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - TranscriptionProvider

    public func isAvailable() async -> Bool {
        guard isAvailableCheck() else { return false }
        let installed = await installedLocalesCheck()
        return !installed.isEmpty
    }

    public func currentModel() async -> String? {
        guard isAvailableCheck() else { return nil }
        let requested = STTLocale.resolveRequestedLocale(nil)
        guard let target = await supportedLocale(requested) else { return nil }
        return target.identifier(.bcp47)
    }

    public func transcribe(fileURL: URL, language: String?) async throws -> TranscriptionResult {
        try Task.checkCancellation()

        // 1. Gate on real engine availability first (mirrors `Transcribe.swift:84-88`). Never
        //    proceed to open/analyze audio when the engine itself can't run.
        guard isAvailableCheck() else {
            throw TranscriptionError.providerUnavailable(
                "SpeechTranscriber is not available on this device — on-device transcription is unusable"
            )
        }

        // 2. Resolve the requested locale to the engine's supported equivalent (← `STTLocale`,
        //    `Transcribe.swift:100-104`). No supported equivalent at all → honest
        //    `.unsupportedLanguage`, never a silently-wrong-locale transcript.
        let requested = STTLocale.resolveRequestedLocale(language)
        guard let target = await supportedLocale(requested) else {
            throw TranscriptionError.unsupportedLanguage(requested.identifier(.bcp47))
        }
        let targetID = target.identifier(.bcp47)

        // 3. Require the resolved locale's model assets to already be installed — we do NOT
        //    silently download here (that is `SpeechAssetManager.install`'s job).
        let installed = await installedLocalesCheck()
        guard installed.contains(where: { $0.identifier(.bcp47) == targetID }) else {
            throw TranscriptionError.assetsNotInstalled(locale: targetID)
        }

        try Task.checkCancellation()

        // 4. Open the audio file (← `Entry.swift:138-140`). An open failure is an honest decode
        //    error, never a fabricated empty transcript.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionError.audioDecodeFailed(
                "could not open audio file at \(fileURL.path): \(error.localizedDescription)"
            )
        }
        let audioDurationSec = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        // 5. Build the transcriber, opting in to per-run confidence + word timing attributes (←
        //    `Entry.swift:163-168`).
        let transcriber = SpeechTranscriber(
            locale: target,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 5b. Custom vocabulary (docs/plans/custom-vocabulary.md §2.4/§3): fetched EXACTLY ONCE,
        //     before analysis starts. `nil` bias attaches no context at all.
        let bias = await vocabularyBias()
        await Self.applyVocabularyBias(bias, to: analyzer)

        // 6. Drain results concurrently with feeding the file. The child Task RETURNS its
        //    collected value (not a captured outer `var`), keeping the collector Sendable-clean
        //    under Swift 6 strict concurrency (← `Entry.swift:194-217`).
        let collector: Task<[TranscriptionSegment], Error> = Task {
            var segments: [TranscriptionSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters)
                let startSec = CMTimeMapping.seconds(result.range.start)
                let endSec = CMTimeMapping.seconds(result.range.end)
                let (words, meanConfidence) = CMTimeMapping.extractWordTimings(from: result.text)
                segments.append(TranscriptionSegment(
                    text: text,
                    startSec: startSec,
                    endSec: endSec,
                    confidence: meanConfidence,
                    words: words
                ))
            }
            return segments
        }

        // 7. Feed the WHOLE file to a single session (← `Entry.swift:240-249`) — no manual
        //    chunking. Finalize through the last analyzed sample time so the results sequence
        //    completes and `collector` above returns.
        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw TranscriptionError.engineFailed(
                "SpeechAnalyzer failed to process \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }

        let segments: [TranscriptionSegment]
        do {
            segments = try await collector.value
        } catch {
            throw TranscriptionError.engineFailed(
                "failed while reading transcription results: \(error.localizedDescription)"
            )
        }

        // 8. Empty finalized text (silence/non-speech) is a real outcome, returned verbatim — we
        //    never invent words (No-Fake-State, ← `Transcribe.swift:185-188`).
        let fullText = segments.map(\.text).joined(separator: " ")
        let wordTimestampCount = segments.reduce(0) { $0 + $1.words.count }

        return TranscriptionResult(
            segments: segments,
            fullText: fullText,
            audioDurationSec: audioDurationSec,
            wordTimestampCount: wordTimestampCount
        )
    }

    /// LIVE path (plan §2.3/§5 Slice E — DESIGNED + compiled + shape/cancellation-tested, NOT
    /// verified against real mic capture this stint; Phase 3.2 feeds it real buffers under TCC).
    ///
    /// Absorbs apple-helper's `analyzer.start(inputSequence:)` + `AnalyzerInput` usage
    /// (`Transcribe.swift:165-170`), generalized to a caller-owned, open-ended stream instead of
    /// one bounded segment:
    ///   1. Same honest gating as the file path (engine availability → locale resolution → asset
    ///      installation) — never starts an analyzer session it can't back with a real model.
    ///   2. Builds an INTERNAL `AsyncStream<AnalyzerInput>` that WE own (not `liveInputs` directly)
    ///      and start the analyzer over that — this is what lets us signal true end-of-input
    ///      deterministically once `liveInputs` is exhausted, mirroring how `Transcribe.swift`
    ///      calls `inputBuilder.finish()` itself before finalizing.
    ///   3. Forwards `liveInputs` into that internal stream non-blocking — STT never touches the
    ///      audio callback thread (plan §3); this is plain in-process forwarding, not inference.
    ///   4. Drains `transcriber.results` concurrently via a structured `async let` child (the
    ///      Sendable-clean collector pattern, `Entry.swift:194-217`, generalized to yield each
    ///      finalized segment through the returned stream instead of collecting an array) —
    ///      volatile (non-final) results are consumed and discarded internally, never surfaced.
    ///   5. Cancellation: `AsyncThrowingStream`'s `onTermination` cancels the outer task (← the
    ///      `LLMClient.stream` pattern, `LLMClient.swift:44`); the `async let` results-drain is a
    ///      STRUCTURED child of that task, so cancelling/exiting the outer task's scope cancels and
    ///      awaits it automatically — no manual second-task cancel-cascade, no `@unchecked Sendable`.
    public func transcribe(
        liveInputs: some AsyncSequence<AnalyzerInput, Never> & Sendable,
        language: String?
    ) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()

                    // 1. Same honest gating as the file path — never open a live session the
                    //    engine/assets genuinely can't back.
                    guard isAvailableCheck() else {
                        throw TranscriptionError.providerUnavailable(
                            "SpeechTranscriber is not available on this device — on-device transcription is unusable"
                        )
                    }
                    let requested = STTLocale.resolveRequestedLocale(language)
                    guard let target = await supportedLocale(requested) else {
                        throw TranscriptionError.unsupportedLanguage(requested.identifier(.bcp47))
                    }
                    let targetID = target.identifier(.bcp47)
                    let installed = await installedLocalesCheck()
                    guard installed.contains(where: { $0.identifier(.bcp47) == targetID }) else {
                        throw TranscriptionError.assetsNotInstalled(locale: targetID)
                    }

                    try Task.checkCancellation()

                    let transcriber = SpeechTranscriber(
                        locale: target,
                        transcriptionOptions: [],
                        reportingOptions: [],
                        attributeOptions: [.audioTimeRange, .transcriptionConfidence]
                    )
                    let analyzer = SpeechAnalyzer(modules: [transcriber])

                    // Custom vocabulary (docs/plans/custom-vocabulary.md §2.4/§3): fetched EXACTLY
                    // ONCE per live session, before the analyzer starts — never inside the
                    // per-buffer forwarding loop below. `nil` bias attaches no context at all.
                    let bias = await vocabularyBias()
                    await Self.applyVocabularyBias(bias, to: analyzer)

                    // 4. Drain finalized results concurrently as a STRUCTURED child (`async let`),
                    //    yielding each one through `continuation` as soon as it finalizes — volatile
                    //    results are consumed by the `guard result.isFinal` and never surfaced.
                    async let drainResults: Void = {
                        for try await result in transcriber.results {
                            guard result.isFinal else { continue }
                            let text = String(result.text.characters)
                            let startSec = CMTimeMapping.seconds(result.range.start)
                            let endSec = CMTimeMapping.seconds(result.range.end)
                            let (words, meanConfidence) = CMTimeMapping.extractWordTimings(from: result.text)
                            continuation.yield(TranscriptionSegment(
                                text: text,
                                startSec: startSec,
                                endSec: endSec,
                                confidence: meanConfidence,
                                words: words
                            ))
                        }
                    }()

                    // 2. Start the analyzer over an INTERNAL stream we control, so WE can signal
                    //    true end-of-input once `liveInputs` is exhausted.
                    let (internalSequence, internalContinuation) = AsyncStream<AnalyzerInput>.makeStream()
                    do {
                        try await analyzer.start(inputSequence: internalSequence)
                    } catch {
                        throw TranscriptionError.engineFailed(
                            "SpeechAnalyzer failed to start the live session: \(error.localizedDescription)"
                        )
                    }

                    // 3. Forward the caller-owned sequence in, non-blocking — CONVERTING each
                    //    buffer to the analyzer's negotiated format first. SpeechAnalyzer traps
                    //    (SIGTRAP inside SpeechRecognizerWorker.processAudio) when handed a
                    //    format it didn't agree to, so raw 48 kHz capture buffers must never
                    //    reach it directly (crash found in Lane 2, 2026-07-21). One converter
                    //    is reused across the loop so sample-rate-conversion filter state stays
                    //    continuous between buffers.
                    let preferredFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: [transcriber]
                    )
                    var conversion: (converter: AVAudioConverter, from: AVAudioFormat)?
                    for await input in liveInputs {
                        try Task.checkCancellation()
                        guard let preferredFormat else {
                            internalContinuation.yield(input)
                            continue
                        }
                        if let converted = try Self.convertLiveBuffer(
                            input.buffer, to: preferredFormat, reusing: &conversion
                        ) {
                            internalContinuation.yield(AnalyzerInput(buffer: converted))
                        }
                    }
                    internalContinuation.finish()

                    do {
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                    } catch {
                        throw TranscriptionError.engineFailed(
                            "SpeechAnalyzer failed to finalize the live session: \(error.localizedDescription)"
                        )
                    }

                    // Await the structured drain child — it completes once `transcriber.results`
                    // finishes (which `finalizeAndFinishThroughEndOfInput()` above triggers).
                    do {
                        try await drainResults
                    } catch {
                        throw TranscriptionError.engineFailed(
                            "failed while reading live transcription results: \(error.localizedDescription)"
                        )
                    }

                    continuation.finish()
                } catch is CancellationError {
                    // A cooperative cancellation (either ours or the caller's) ends the stream
                    // cleanly with no error — this is a normal stop, not a failure.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Converts one live capture buffer to the analyzer's negotiated format, reusing a single
    /// `AVAudioConverter` across calls (fresh only when the source format changes) so the
    /// sample-rate converter's filter state stays continuous — per-buffer converters produce
    /// audible seams. Returns `nil` for an honestly-empty conversion (no fabricated audio).
    private static func convertLiveBuffer(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat,
        reusing state: inout (converter: AVAudioConverter, from: AVAudioFormat)?
    ) throws -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }

        let converter: AVAudioConverter
        if let existing = state, existing.from == buffer.format {
            converter = existing.converter
        } else {
            guard let fresh = AVAudioConverter(from: buffer.format, to: format) else {
                throw TranscriptionError.engineFailed(
                    "could not create a live-audio converter from \(buffer.format) to \(format)"
                )
            }
            state = (fresh, buffer.format)
            converter = fresh
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.engineFailed("could not allocate a live-audio conversion buffer")
        }

        // `@unchecked Sendable`, justified: `AVAudioConverterInputBlock` is typed `@Sendable`,
        // but `convert(to:error:withInputFrom:)` documents calling it synchronously on the
        // calling thread during this one call — there is no actual concurrent access to `fed`
        // or the buffer.
        final class InputFeed: @unchecked Sendable {
            var fed = false
            let buffer: AVAudioPCMBuffer
            init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let feed = InputFeed(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if feed.fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.fed = true
            outStatus.pointee = .haveData
            return feed.buffer
        }
        if let conversionError {
            throw TranscriptionError.engineFailed(
                "live audio conversion failed: \(conversionError.localizedDescription)"
            )
        }
        guard status != .error else {
            throw TranscriptionError.engineFailed("live audio conversion failed")
        }
        return output.frameLength > 0 ? output : nil
    }
}
