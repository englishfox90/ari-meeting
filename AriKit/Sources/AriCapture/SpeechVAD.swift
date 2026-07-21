//
//  SpeechVAD.swift — the VAD segmenter STATE MACHINE (arikit-native-shell.md §4.5, §9-3,
//  ← `frontend/src-tauri/src/audio/vad.rs` `ContinuousVadProcessor`, :17-289, and the
//  downstream min-length gate at `pipeline.rs:892`).
//
//  This ports the DETERMINISTIC wrapper logic around a speech-probability stream — in/out-of-
//  speech state, enter/exit thresholds, redemption (grace period that bridges natural pauses so
//  continuous speech doesn't fragment), and a minimum-segment-length gate. It does NOT port
//  Silero itself (a neural net) or wire a live probability source: `SpeechVADSegmenter.process`
//  is fed externally-computed per-frame probabilities, and `SpeechProbabilitySource` is left as
//  an unwired protocol seam for whichever backend (Apple `SpeechDetector` vs a CoreML silero) is
//  chosen at the device slice (plan §9-3 — explicitly deferred, not decided here).
//
//  Divergence from the Rust recipe (documented, not silent): `vad.rs`'s own `VadConfig` uses
//  `min_speech_time = 250ms` (4,000 samples @ 16 kHz) as Silero's internal fragment filter, but
//  the task for THIS slice pins the segmenter's min-segment gate to the downstream check at
//  `pipeline.rs:892` instead — **800 samples / 50 ms @ 16 kHz** ("Minimum 50ms... matches
//  Parakeet capability"). A single gate keeps the pure port simple and directly matches the
//  plan's explicit instruction; `minSpeechTimeMs` is not separately enforced.
//
//  Pure state, no I/O, no AVFoundation — headless-testable on fixture probability/PCM sequences
//  (Lane 1, plan §7 `SpeechVADTests`).
//

/// A completed speech segment (← `SpeechSegment`, `vad.rs:7-14`).
public struct SpeechSegment: Sendable, Equatable {
    /// Mono PCM samples at the segmenter's `sampleRate` (16 kHz by default — Silero's hard
    /// requirement, `vad.rs:33-34`).
    public var samples: [Float]
    public var startTimestampMs: Double
    public var endTimestampMs: Double
    public var confidence: Float

    public init(samples: [Float], startTimestampMs: Double, endTimestampMs: Double, confidence: Float) {
        self.samples = samples
        self.startTimestampMs = startTimestampMs
        self.endTimestampMs = endTimestampMs
        self.confidence = confidence
    }
}

/// Tuning knobs for `SpeechVADSegmenter` (← `VadConfig` fields actually used by the incumbent,
/// `vad.rs:37-56`, with the min-segment gate reconciled to `pipeline.rs:892` per the note above).
public struct SpeechVADConfig: Sendable, Equatable {
    /// Enter-speech probability threshold (← `positive_speech_threshold`, `vad.rs:43`).
    public var positiveSpeechThreshold: Float = 0.50
    /// Exit-speech probability threshold (← `negative_speech_threshold`, `vad.rs:44`).
    public var negativeSpeechThreshold: Float = 0.35
    /// Grace period (ms) a sub-`negativeSpeechThreshold` run must persist before the segment is
    /// actually closed — bridges natural mid-sentence pauses (← `redemption_time`, `vad.rs:49`;
    /// the live pipeline's macOS default is 400 ms, `pipeline.rs:731`).
    public var redemptionTimeMs: Double = 400
    /// Minimum completed-segment length, in samples at `sampleRate`, to emit rather than drop
    /// (← the downstream gate `pipeline.rs:892`: 800 samples = 50 ms @ 16 kHz).
    public var minSegmentSamples: Int = 800
    /// Nominal analysis frame size in samples (← the Silero chunk size, `vad.rs:65`: 30 ms @
    /// 16 kHz = 480 samples). `process(frame:probability:)` accepts any frame size; this value
    /// only affects the frame-duration math used for redemption timing.
    public var frameSizeSamples: Int = 480
    /// Sample rate of frames fed to the segmenter. Silero's hard requirement is 16 kHz
    /// (`vad.rs:33-34`) — callers resample the mixed 48 kHz window down before feeding this type.
    public var sampleRate: Double = 16000

    public init() {}
}

/// Protocol seam for the per-frame speech-probability SOURCE (Apple `SpeechDetector` vs a
/// CoreML-silero model — plan §9-3, decided at the device slice). Deliberately unimplemented and
/// unwired here: `SpeechVADSegmenter` never calls this itself, so no live Speech-framework
/// dependency enters this headless target.
public protocol SpeechProbabilitySource: Sendable {
    /// Speech probability in `[0, 1]` for one 16 kHz analysis frame.
    func probability(for frame: [Float]) async throws -> Float
}

/// The pure in/out-of-speech state machine (← `ContinuousVadProcessor`, `vad.rs:17-289`, minus
/// the actual Silero inference — probabilities are supplied by the caller per frame).
///
/// Reference semantics (mutates internal state per call) — mirrors the Rust struct's `&mut self`
/// methods. Not `Sendable`: callers own single-threaded/actor-isolated access, matching how the
/// Rust `ContinuousVadProcessor` is owned exclusively by one `AudioPipeline` task.
public final class SpeechVADSegmenter {
    private let config: SpeechVADConfig
    private var inSpeech = false
    private var currentSpeech: [Float] = []
    private var processedSamples = 0
    private var speechStartSample = 0
    private var belowThresholdDurationMs = 0.0

    public init(config: SpeechVADConfig = SpeechVADConfig()) {
        self.config = config
    }

    /// Feed one analysis frame with its externally-computed speech probability.
    ///
    /// Returns the segment that just completed, if this frame closed one (a single frame closes
    /// at most one segment) — `nil` while still accumulating, still silent, or when the
    /// completed segment was too short to emit (honest drop, No-Fake-State: never a fabricated
    /// stand-in segment).
    public func process(frame: [Float], probability: Float) -> SpeechSegment? {
        defer { processedSamples += frame.count }

        if !inSpeech {
            guard probability >= config.positiveSpeechThreshold else { return nil }
            inSpeech = true
            currentSpeech = frame
            speechStartSample = processedSamples
            belowThresholdDurationMs = 0
            return nil
        }

        currentSpeech.append(contentsOf: frame)

        if probability < config.negativeSpeechThreshold {
            belowThresholdDurationMs += frameDurationMs(for: frame)
            guard belowThresholdDurationMs >= config.redemptionTimeMs else { return nil }
            return closeSegment()
        }

        // Still speaking (probability rebounded above the exit threshold): reset the grace
        // counter so a brief dip below `negativeSpeechThreshold` doesn't accumulate toward the
        // redemption window across separate dips (mirrors the incumbent bridging a single pause,
        // not summing several).
        belowThresholdDurationMs = 0
        return nil
    }

    /// Force-end any open segment at end-of-stream (← `flush()`, `vad.rs:167-214`). Honest `nil`
    /// if nothing was open, or if what was open didn't clear the min-segment gate.
    public func flush() -> SpeechSegment? {
        guard inSpeech, !currentSpeech.isEmpty else {
            inSpeech = false
            currentSpeech = []
            return nil
        }
        return closeSegment()
    }

    private func closeSegment() -> SpeechSegment? {
        let samples = currentSpeech
        let startMs = samplesToMs(speechStartSample)
        // The end timestamp is simply start + accumulated segment duration — every frame fed
        // while `inSpeech` (including the grace-period frames) was appended to `currentSpeech`.
        let endMs = startMs + samplesToMs(samples.count)

        inSpeech = false
        currentSpeech = []
        belowThresholdDurationMs = 0

        guard samples.count >= config.minSegmentSamples else { return nil }

        return SpeechSegment(
            samples: samples,
            startTimestampMs: startMs,
            endTimestampMs: endMs,
            confidence: 0.9
        )
    }

    private func frameDurationMs(for frame: [Float]) -> Double {
        Double(frame.count) / config.sampleRate * 1000.0
    }

    private func samplesToMs(_ samples: Int) -> Double {
        Double(samples) / config.sampleRate * 1000.0
    }
}
