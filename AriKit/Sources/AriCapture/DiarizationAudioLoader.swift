//
//  DiarizationAudioLoader.swift — decodes any AVFoundation-readable meeting recording to
//  16 kHz mono [-1, 1] float PCM for the diarization pipeline (plan §2.7, §5 D6).
//
//  A distinct converter path from `Resampler.swift` (which targets the capture pipeline's
//  internal 48 kHz rate): diarization needs FluidAudio's 16 kHz input rate instead, and this
//  loader decodes a whole saved file rather than resampling a live-capture window. Pure
//  file-to-buffer decode + `AVAudioConverter` (sample rate AND channel downmix in one step,
//  since `AVAudioConverter` handles arbitrary channel-count conversion between standard
//  formats); no device I/O, headless-testable on a bundled fixture. `#if os(macOS)`-gated per
//  plan §2.1 (`AriCapture` is a macOS-only product).
//
#if os(macOS)
    // See `Resampler.swift` for why AVAudioConverter's block-based `convert(to:error:
    // withInputFrom:)` needs `@preconcurrency` here: its pull callback is imported as
    // `@Sendable` even though Apple's docs guarantee synchronous, single-thread, non-concurrent
    // invocation — a known false positive for this exact API shape.
    @preconcurrency import AVFoundation
    import AriKit
    import Foundation

    /// Decodes an AVFoundation-readable audio file to 16 kHz mono `[-1, 1]` float PCM.
    public struct DiarizationAudioLoader: DiarizationAudioLoading, Sendable {
        /// FluidAudio's required input rate (← `DiarizationProvider.diarize` contract, plan §2.2).
        public static let targetSampleRate: Double = 16000

        public init() {}

        /// Honest errors only — never a fabricated/empty PCM buffer for an unreadable file
        /// (No-Fake-State). Multi-channel input is downmixed to mono by the same conversion
        /// step that resamples to 16 kHz.
        public func load16kMono(from url: URL) async throws -> [Float] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DiarizationError.audioUnreadable("no file at \(url.path)")
            }

            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                throw DiarizationError.audioUnreadable(error.localizedDescription)
            }

            guard file.length > 0 else { return [] }

            guard let targetFormat = AVAudioFormat(
                standardFormatWithSampleRate: Self.targetSampleRate,
                channels: 1
            ) else {
                throw DiarizationError.audioUnreadable("could not construct 16 kHz mono target format")
            }

            guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
                throw DiarizationError
                    .audioUnreadable("could not construct format converter for \(url.lastPathComponent)")
            }

            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else {
                throw DiarizationError.audioUnreadable("could not allocate input buffer for \(url.lastPathComponent)")
            }

            do {
                try file.read(into: inputBuffer)
            } catch {
                throw DiarizationError.audioUnreadable(error.localizedDescription)
            }

            let ratio = Self.targetSampleRate / file.processingFormat.sampleRate
            // Small safety margin, same rationale as `Resampler`: the converter may need a
            // couple of extra output frames for its internal filter state.
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 16
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw DiarizationError
                    .audioUnreadable("could not allocate output buffer for \(url.lastPathComponent)")
            }

            var conversionError: NSError?
            // `nonisolated(unsafe)`, justified as in `Resampler.swift`: `AVAudioConverter`
            // invokes this block synchronously on the calling thread, possibly more than once,
            // never concurrently and never after `convert` returns — a documented, single-
            // threaded pull contract, not a real data race.
            nonisolated(unsafe) var inputConsumed = false
            nonisolated(unsafe) let pendingInputBuffer = inputBuffer
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return pendingInputBuffer
            }

            if status == .error {
                throw DiarizationError.audioUnreadable(
                    conversionError?.localizedDescription ?? "unknown AVAudioConverter error decoding \(url.lastPathComponent)"
                )
            }

            guard let outputChannelData = outputBuffer.floatChannelData else { return [] }
            let frameLength = Int(outputBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: outputChannelData[0], count: frameLength))
        }
    }
#endif
