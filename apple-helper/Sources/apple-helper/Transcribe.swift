//
//  Transcribe.swift
//  apple-helper
//
//  On-device speech-to-text for the `transcribe` request, factored out of
//  main.swift so it is unit-testable and so the framework calls are isolated.
//
//  Backed by Apple's SpeechAnalyzer / SpeechTranscriber on-device STT engine
//  (macOS 26+). It transcribes ONE complete, bounded audio segment (a single VAD
//  speech window) and returns the finalized best transcript. Every result
//  reflects a REAL model transcription — this function NEVER fabricates text or a
//  confidence value (No-Fake-State). On ANY failure (engine unavailable, locale
//  assets missing, decode error, empty/short audio, or a thrown transcription
//  error) it THROWS a descriptive `TranscribeError`; main.swift catches and emits
//  an `AppleResponse.error(message:)` instead of a fake transcript.
//
//  Symbols verified against the macOS 26 SDK swiftinterface
//  (Speech.framework, arm64e-apple-macos.swiftinterface):
//    - `SpeechTranscriber.isAvailable: Bool` (static, sync)                  [line 399]
//    - `SpeechTranscriber.installedLocales: [Locale]` (static, async)        [line 406]
//    - `SpeechTranscriber.supportedLocale(equivalentTo:) -> Locale?`         [line 405]
//    - `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:
//         attributeOptions:)` convenience init                              [line 337]
//    - `SpeechTranscriber.ResultAttributeOption.transcriptionConfidence`
//         (+ `.audioTimeRange`) — opt in to per-run confidence attributes    [line 385-386]
//    - `SpeechAnalyzer(modules:options:)` actor init                        [line 208]
//    - `SpeechAnalyzer.start(inputSequence:)` where the sequence element is
//         `AnalyzerInput`                                                    [line 217]
//    - `AnalyzerInput(buffer: AVAudioPCMBuffer)`                            [line 244]
//    - `SpeechAnalyzer.finalizeAndFinishThroughEndOfInput()`               [line 220]
//    - `SpeechTranscriber.results` → AsyncSequence of `SpeechTranscriber.Result`
//         with `.text: AttributedString`, `.isFinal` (SpeechModuleResult)   [line 415-433]
//    - Confidence is exposed as an AttributedString run attribute:
//         `AttributeScopes.SpeechAttributes.ConfidenceAttribute`,
//         `Value == Double`, reached via dynamic member `run.transcriptionConfidence`
//         when `.transcriptionConfidence` is requested.                     [line 172-177]
//    - `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`           [line 233]
//
//  ENTITLEMENTS: on-device SpeechAnalyzer/SpeechTranscriber transcription needs
//  NO special entitlement. The new engine exposes NO authorization API
//  (there is no `requestAuthorization` / `authorizationStatus` in this path —
//  verified absent from the swiftinterface), unlike the OLDER server-backed
//  `SFSpeechRecognizer`, which is what the classic
//  `com.apple.developer.speech-recognition` entitlement + `NSSpeechRecognitionUsageDescription`
//  gate. The on-device transcription runs in-process against locally-installed
//  model assets (installed via AssetInventory — see EnsureAssets.swift) with no
//  TCC-guarded resource and no network. No entitlements file was added. See the
//  task report for the full reasoning; this should be re-confirmed on a machine
//  running the signed app against real audio.
//

import Foundation
import Speech
import AVFoundation

/// A descriptive, honest failure from the transcribe path. Its `message` is what
/// the sidecar surfaces to the Rust core as `AppleResponse.error(message:)`.
struct TranscribeError: Error, Equatable {
    let message: String
}

enum Transcribe {

    /// The fixed input contract: raw little-endian Float32, 16 kHz, mono PCM.
    static let inputSampleRate: Double = 16_000
    static let inputChannels: AVAudioChannelCount = 1

    /// Transcribe ONE complete audio segment and return the finalized best
    /// transcript plus an optional confidence.
    ///
    /// - Parameters:
    ///   - pcmBase64: base64 of raw little-endian Float32, 16 kHz, mono PCM
    ///     samples (a single VAD speech segment).
    ///   - locale: BCP-47 locale identifier (e.g. `"en-US"`) selecting the model.
    /// - Returns: `(text, confidence)` where `text` is the finalized transcript
    ///   and `confidence` is the mean per-run confidence in `[0, 1]` when the SDK
    ///   reports it, or `nil` when it does not (never fabricated).
    /// - Throws: `TranscribeError` with a truthful reason on engine
    ///   unavailability, missing locale assets, a base64/format decode failure,
    ///   empty/short audio, or a thrown transcription error. Never returns
    ///   fabricated text.
    static func run(pcmBase64: String, locale localeID: String) async throws -> (text: String, confidence: Double?) {
        // 1. Gate on real engine availability first (mirrors Probe.swift).
        guard SpeechTranscriber.isAvailable else {
            throw TranscribeError(
                message: "SpeechTranscriber is not available on this device — on-device transcription is unusable"
            )
        }

        // 2. Resolve the requested locale to the engine's supported equivalent,
        //    and require its model assets to already be installed. We do NOT
        //    silently download here — that is the `ensureAssets` request's job.
        //
        //    The app's transcription language may be the sentinel "auto" /
        //    "auto-translate" (auto-detect — meaningful to Whisper/Parakeet but
        //    not a real Locale) or empty. Map those to `Locale.current`, the SAME
        //    resolution `EnsureAssets`/`Probe` use, so transcribe asks for exactly
        //    the locale whose assets were installed and probed. Without this, a
        //    "auto" request never matches installedLocales and throws below.
        let normalizedID = localeID.lowercased()
        let requested = (localeID.isEmpty || normalizedID == "auto" || normalizedID == "auto-translate")
            ? Locale.current
            : Locale(identifier: localeID)
        let target = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested
        let targetID = target.identifier(.bcp47)

        let installed = await SpeechTranscriber.installedLocales
        let assetsInstalled = installed.contains { $0.identifier(.bcp47) == targetID }
        guard assetsInstalled else {
            throw TranscribeError(
                message: "speech model for \(targetID) is not installed — install it before transcribing"
            )
        }

        // 3. Decode base64 → [Float] (little-endian Float32). Empty/too-short
        //    input is an honest failure, never a fabricated empty transcript.
        let samples = try decodePCMFloat32LE(base64: pcmBase64)
        guard !samples.isEmpty else {
            throw TranscribeError(message: "decoded audio segment is empty — nothing to transcribe")
        }

        // 4. Build the transcriber, opting in to per-run confidence attributes so
        //    we can report a real confidence (No-Fake-State: nil if absent).
        let transcriber = SpeechTranscriber(
            locale: target,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )

        // 5. Wrap the samples into an AVAudioPCMBuffer at the input contract
        //    format (16 kHz mono float32), then convert to the format the
        //    analyzer actually wants (if different) so the engine accepts it.
        let inputBuffer = try makeInputBuffer(from: samples)
        let feedBuffer = try await convertIfNeeded(inputBuffer, for: transcriber)

        // 6. Create the analyzer over the single transcriber module.
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 7. Drain the transcriber's results concurrently. The results sequence
        //    completes when the analyzer finishes end-of-input. We keep only
        //    finalized results and concatenate their text; we average whatever
        //    real per-run confidence attributes the SDK attaches.
        let collector = Task { () -> (String, Double?) in
            var pieces: [String] = []
            var confidenceSum = 0.0
            var confidenceCount = 0
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let attributed = result.text
                pieces.append(String(attributed.characters))
                for run in attributed.runs {
                    if let c = run.transcriptionConfidence {
                        confidenceSum += c
                        confidenceCount += 1
                    }
                }
            }
            let text = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence = confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : nil
            return (text, confidence)
        }

        // 8. Feed the whole segment as ONE bounded input sequence, then finalize.
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.start(inputSequence: inputSequence)
            inputBuilder.yield(AnalyzerInput(buffer: feedBuffer))
            inputBuilder.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw TranscribeError(message: "on-device transcription failed: \(error.localizedDescription)")
        }

        // 9. Await the collected transcript. A thrown error from the results
        //    stream is surfaced honestly.
        let (text, confidence): (String, Double?)
        do {
            (text, confidence) = try await collector.value
        } catch {
            throw TranscribeError(message: "on-device transcription failed while reading results: \(error.localizedDescription)")
        }

        // 10. Empty finalized text is a real outcome for silence/non-speech; we
        //     return it verbatim (No-Fake-State — we do NOT invent words). The
        //     Rust side decides what an empty segment means.
        return (text, confidence)
    }

    // MARK: - Base64 → [Float] (little-endian Float32)

    /// Decode a base64 string into `[Float]`, interpreting the raw bytes as
    /// little-endian IEEE-754 Float32. Throws on invalid base64 or a byte count
    /// that is not a multiple of 4 (a truncated/misaligned sample stream).
    ///
    /// Factored out and made `internal` so it is unit-testable without any audio
    /// runtime.
    static func decodePCMFloat32LE(base64: String) throws -> [Float] {
        guard let data = Data(base64Encoded: base64) else {
            throw TranscribeError(message: "audio payload is not valid base64")
        }
        guard data.count % 4 == 0 else {
            throw TranscribeError(
                message: "audio payload length \(data.count) is not a multiple of 4 — not aligned Float32 PCM"
            )
        }
        let count = data.count / 4
        var floats = [Float](repeating: 0, count: count)
        // Reassemble each little-endian 4-byte group into a Float32. Using
        // UInt32 bit-reconstruction avoids any host-endianness / alignment
        // assumptions on the raw Data buffer.
        for i in 0..<count {
            let base = i * 4
            let b0 = UInt32(data[data.startIndex + base])
            let b1 = UInt32(data[data.startIndex + base + 1])
            let b2 = UInt32(data[data.startIndex + base + 2])
            let b3 = UInt32(data[data.startIndex + base + 3])
            let bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            floats[i] = Float(bitPattern: bits)
        }
        return floats
    }

    // MARK: - PCM buffer construction

    /// Build an `AVAudioPCMBuffer` at the fixed input contract format (16 kHz,
    /// mono, float32) filled with `samples`.
    private static func makeInputBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: inputChannels,
            interleaved: false
        ) else {
            throw TranscribeError(message: "failed to build 16 kHz mono float32 audio format")
        }
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData else {
            throw TranscribeError(message: "failed to allocate audio buffer for \(samples.count) samples")
        }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Convert `buffer` to the format the analyzer wants for `transcriber`, if it
    /// differs from the input contract format. Returns the input buffer unchanged
    /// when the engine reports no preferred format or an identical one.
    private static func convertIfNeeded(
        _ buffer: AVAudioPCMBuffer,
        for transcriber: SpeechTranscriber
    ) async throws -> AVAudioPCMBuffer {
        guard let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            // Engine did not report a preferred format — feed our buffer as-is.
            return buffer
        }
        if bestFormat.sampleRate == buffer.format.sampleRate
            && bestFormat.channelCount == buffer.format.channelCount
            && bestFormat.commonFormat == buffer.format.commonFormat {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: bestFormat) else {
            throw TranscribeError(
                message: "failed to build audio converter from \(buffer.format.sampleRate) Hz to \(bestFormat.sampleRate) Hz"
            )
        }
        // Size the output for the resampled frame count (round up).
        let ratio = bestFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: bestFormat, frameCapacity: max(outCapacity, 1)) else {
            throw TranscribeError(message: "failed to allocate converted audio buffer")
        }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw TranscribeError(message: "audio format conversion failed: \(conversionError.localizedDescription)")
        }
        guard status != .error else {
            throw TranscribeError(message: "audio format conversion returned an error status")
        }
        return outBuffer
    }
}
