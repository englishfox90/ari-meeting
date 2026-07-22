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

        /// Chunk size (in source-format seconds) read per pull-loop iteration (D6 review fix).
        /// A whole-file `AVAudioPCMBuffer(frameCapacity: file.length)` at the SOURCE format is a
        /// multi-GB transient for a long meeting (e.g. ~2.7 GB for a 2-hour 48 kHz stereo f32
        /// import) — far beyond the ~150 MB the plan (§4) budgets for the 16k-mono OUTPUT that
        /// crosses the actor boundary. Streaming the decode in fixed-size chunks keeps only the
        /// growing mono 16k output resident, not the full source-format recording.
        private static let chunkSeconds: Double = 3.0

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
            // `AVAudioConverter.downmix` defaults to `false`, in which case a channel-count
            // reduction maps output <- input channel 0 and silently DISCARDS every other
            // channel, rather than mixing them. Without this, multi-channel input with signal
            // predominantly (or only) outside channel 0 decodes to near-silence — a real
            // No-Fake-State risk for imported stereo/dual-mono meeting files.
            converter.downmix = true

            // Streaming decode (D6 review fix): read the source file in fixed-size chunks inside
            // the converter's pull callback rather than buffering the whole recording at the
            // source format up front. Only the growing 16k-mono OUTPUT accumulates in memory.
            let chunkFrameCapacity = AVAudioFrameCount(
                (Self.chunkSeconds * file.processingFormat.sampleRate).rounded(.up)
            )
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: max(chunkFrameCapacity, 1)
            ) else {
                throw DiarizationError.audioUnreadable("could not allocate input buffer for \(url.lastPathComponent)")
            }

            let ratio = Self.targetSampleRate / file.processingFormat.sampleRate
            // Small safety margin, same rationale as `Resampler`: the converter may need a
            // couple of extra output frames for its internal filter state.
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameCapacity) * ratio) + 16
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw DiarizationError
                    .audioUnreadable("could not allocate output buffer for \(url.lastPathComponent)")
            }

            // `nonisolated(unsafe)`, justified as in `Resampler.swift`: `AVAudioConverter`
            // invokes this block synchronously on the calling thread, possibly more than once,
            // never concurrently and never after `convert` returns — a documented, single-
            // threaded pull contract, not a real data race.
            nonisolated(unsafe) var reachedEndOfFile = false
            nonisolated(unsafe) var readError: Error?
            nonisolated(unsafe) let pendingInputBuffer = inputBuffer
            let pendingFile = file

            var samples: [Float] = []
            samples.reserveCapacity(Int(Self.targetSampleRate * 60)) // rough starting capacity

            while true {
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                    // The converter's pull loop calls this block again even after a prior call
                    // already drained the file — so guard on `framePosition >= length` BEFORE
                    // reading. `AVAudioFile.read(into:frameCount:)` at true EOF throws a generic
                    // `nilError` rather than returning a 0-frame success, unlike the mid-file
                    // case (which returns fewer frames than requested, no throw).
                    if reachedEndOfFile || pendingFile.framePosition >= pendingFile.length {
                        // `.endOfStream`, not `.noDataNow`: no more input is ever coming for
                        // this chunk-read loop's tail, so the converter must flush its internal
                        // sample-rate-conversion filter rather than stopping early.
                        reachedEndOfFile = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    pendingInputBuffer.frameLength = 0
                    do {
                        try pendingFile.read(into: pendingInputBuffer, frameCount: chunkFrameCapacity)
                    } catch {
                        readError = error
                        reachedEndOfFile = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    if pendingInputBuffer.frameLength == 0 {
                        reachedEndOfFile = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return pendingInputBuffer
                }

                if let readError {
                    throw DiarizationError.audioUnreadable(readError.localizedDescription)
                }
                if status == .error {
                    throw DiarizationError.audioUnreadable(
                        conversionError?.localizedDescription ?? "unknown AVAudioConverter error decoding \(url.lastPathComponent)"
                    )
                }

                if let outputChannelData = outputBuffer.floatChannelData {
                    let frameLength = Int(outputBuffer.frameLength)
                    if frameLength > 0 {
                        samples.append(contentsOf: UnsafeBufferPointer(start: outputChannelData[0], count: frameLength))
                    }
                }

                if status == .endOfStream {
                    break
                }
            }

            return samples
        }
    }
#endif
