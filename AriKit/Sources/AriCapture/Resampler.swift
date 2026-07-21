//
//  Resampler.swift — AVAudioConverter wrapper to 48 kHz mono float32 (arikit-native-shell.md
//  §4.2/§4.3, ← the resampling step implicit in `audio/capture/microphone.rs` / `pipeline.rs`'s
//  "mic 16→48 kHz resample, system 48 kHz passthrough" contract, coding-conventions.md).
//
//  Pure-ish: no device I/O, just format conversion of an already-decoded PCM buffer — headless-
//  testable on fixture buffers (Lane 1, plan §7 `ResamplerTests`). `#if os(macOS)`-gated per
//  plan §2.2 (AriCapture is a macOS-only product); AVFoundation itself is cross-platform, but
//  this type is only ever consumed by the macOS `Ari` app.
//
#if os(macOS)
    // `@preconcurrency`: AVFoundation's block-based `AVAudioConverter.convert(to:error:
    // withInputFrom:)` imports its pull callback as `@Sendable` even though Apple's docs
    // guarantee it is invoked synchronously, repeatedly, on the calling thread only (it is not
    // a completion handler dispatched elsewhere) — a known false-positive for this exact API
    // shape. `@preconcurrency` demotes the resulting diagnostics to warnings we then resolve
    // explicitly below with justified `nonisolated(unsafe)`, rather than silencing them.
    @preconcurrency import AVFoundation

    /// Resamples mono float32 PCM to `AriCapture`'s internal 48 kHz rate via `AVAudioConverter`.
    public struct Resampler: Sendable {
        /// The pipeline's internal sample rate (← `pipeline.rs` "consistent 48 kHz internal rate").
        public static let targetSampleRate: Double = 48000

        public init() {}

        /// Resample mono `samples` from `sourceSampleRate` to 48 kHz.
        ///
        /// Honest empty on empty input — never fabricates samples for a dropped/empty read
        /// (No-Fake-State). A `sourceSampleRate` that already equals the target is a pass-through
        /// (no conversion, no copy-through-AVAudioConverter round trip).
        public func resample(_ samples: [Float], from sourceSampleRate: Double) throws -> [Float] {
            guard !samples.isEmpty else { return [] }
            guard sourceSampleRate != Self.targetSampleRate else { return samples }

            guard
                let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sourceSampleRate, channels: 1),
                let targetFormat = AVAudioFormat(standardFormatWithSampleRate: Self.targetSampleRate, channels: 1)
            else {
                throw ResamplerError.invalidFormat
            }

            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw ResamplerError.converterCreationFailed
            }

            guard
                let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: AVAudioFrameCount(samples.count)
                ),
                let inputChannelData = inputBuffer.floatChannelData
            else {
                throw ResamplerError.bufferAllocationFailed
            }
            inputBuffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                inputChannelData[0].update(from: base, count: samples.count)
            }

            let ratio = Self.targetSampleRate / sourceSampleRate
            // Small safety margin: the converter may need a couple of extra output frames for its
            // internal filter state, so under-sizing the output buffer would silently truncate.
            let outputCapacity = AVAudioFrameCount(Double(samples.count) * ratio) + 16
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw ResamplerError.bufferAllocationFailed
            }

            var conversionError: NSError?
            // `nonisolated(unsafe)`, justified: `AVAudioConverter.convert(to:error:withInputFrom:)`
            // calls this block synchronously on the current thread, possibly more than once,
            // then returns — per Apple's documented contract, never concurrently and never after
            // `convert` itself returns. The compiler's `@Sendable` inference on the imported
            // ObjC block type is a false positive for this specific, synchronous-only API; there
            // is no actual data race to guard against here.
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
                throw ResamplerError
                    .conversionFailed(conversionError?.localizedDescription ?? "unknown AVAudioConverter error")
            }

            guard let outputChannelData = outputBuffer.floatChannelData else { return [] }
            let frameLength = Int(outputBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: outputChannelData[0], count: frameLength))
        }
    }

    public enum ResamplerError: Error, Equatable, Sendable {
        case invalidFormat
        case converterCreationFailed
        case bufferAllocationFailed
        case conversionFailed(String)
    }
#endif
