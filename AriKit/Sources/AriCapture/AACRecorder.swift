//
//  AACRecorder.swift — AVFoundation AAC-LC encode/decode (arikit-native-shell.md §4.4,
//  ← `frontend/src-tauri/src/audio/encode.rs` `encode_single_audio`, :18-102, which shelled out
//  to ffmpeg; here `AVAudioFile` encodes/decodes directly in-process, replacing that duty of the
//  four-duty ffmpeg sidecar — see plan §4.4 "Encode"/"Decode").
//
//  Headless-testable (Lane 1, plan §7 `AACRecorderRoundTripTests`): `AVAudioFile` read/write
//  works without a signed bundle or any TCC grant — it's plain file I/O, not device capture.
//  `#if os(macOS)`-gated per plan §2.2.
//
#if os(macOS)
    import AVFoundation

    /// Encodes/decodes mono PCM to/from AAC-LC `.m4a`, matching the incumbent's format facts
    /// (coding-conventions.md "Audio facts"): 48 kHz mono AAC, 192 kbps (← `encode.rs:49-54`).
    public struct AACRecorder: Sendable {
        public static let sampleRate: Double = 48000
        public static let bitRate: Int = 192_000

        public init() {}

        /// Encode mono float32 PCM to an AAC-LC `.m4a` file at `url`.
        ///
        /// Throws `AACRecorderError.noAudioData` on empty input rather than writing a fabricated
        /// empty/silent file (No-Fake-State) — mirrors `encode_single_audio`'s
        /// `data.is_empty()` guard (`encode.rs:26-28`).
        public func encode(samples: [Float], to url: URL) throws {
            guard !samples.isEmpty else { throw AACRecorderError.noAudioData }

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: Self.bitRate
            ]

            let file = try AVAudioFile(forWriting: url, settings: settings)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(samples.count)
                ),
                let channelData = buffer.floatChannelData
            else {
                throw AACRecorderError.bufferAllocationFailed
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                channelData[0].update(from: base, count: samples.count)
            }

            try file.write(from: buffer)
        }

        /// Decode an AVFoundation-readable audio file (`.m4a`/`.mp4`/etc.) to mono float32 PCM at
        /// its native sample rate (← `audio/decoder.rs`/ffmpeg decode, used for import +
        /// retranscription). Multi-channel files are downmixed to mono by averaging channels —
        /// the pipeline's mono contract. Callers resample via `Resampler` if a different rate is
        /// needed.
        public func decode(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat

            guard file.length > 0 else { return ([], format.sampleRate) }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw AACRecorderError.bufferAllocationFailed
            }
            try file.read(into: buffer)

            guard let channelData = buffer.floatChannelData else { return ([], format.sampleRate) }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return ([], format.sampleRate) }

            if format.channelCount == 1 {
                return (Array(UnsafeBufferPointer(start: channelData[0], count: frameLength)), format.sampleRate)
            }

            var mono = [Float](repeating: 0, count: frameLength)
            for channel in 0 ..< Int(format.channelCount) {
                let data = channelData[channel]
                for index in 0 ..< frameLength {
                    mono[index] += data[index]
                }
            }
            let channelCount = Float(format.channelCount)
            for index in 0 ..< frameLength {
                mono[index] /= channelCount
            }
            return (mono, format.sampleRate)
        }
    }

    public enum AACRecorderError: Error, Equatable, Sendable {
        case noAudioData
        case bufferAllocationFailed
    }
#endif
