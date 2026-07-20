//
//  TranscriptionProvider.swift — the STT protocol (plan §2.2, ← provider.rs:50).
//
//  The Swift mirror of the Rust `TranscriptionProvider` trait, reshaped: `SpeechTranscriber`
//  segments internally and emits per-word timing + confidence, so this protocol is
//  segment-EMITTING, not the Rust text-in/text-out shape. `Sendable` so it crosses actor
//  boundaries freely. All work is off the main actor by construction.
//
//  The Rust `transcribe(Vec<f32>, Option<String>)` per-VAD-window entrypoint does NOT port
//  directly — its per-window model is subsumed by SpeechTranscriber's internal segmentation on
//  the file path, and by the caller-owned `AnalyzerInput` stream on the live path. There is
//  deliberately no `transcribe([Float])` method here.
//
//  `TranscriptResult.is_partial` (provider.rs:45) is dropped from the public result: the file
//  path keeps only `isFinal` results (Entry.swift:200); the live path surfaces finality by
//  emitting only finalized segments — a documented Swift↔Rust delta (plan §2.2 notes).
//
import Foundation
import Speech

/// One speech-to-text backend. The Swift mirror of the Rust `TranscriptionProvider` trait
/// (provider.rs:50), reshaped: SpeechTranscriber segments internally and emits per-word timing +
/// confidence, so this protocol is segment-EMITTING, not the Rust text-in/text-out shape.
/// `Sendable` so it crosses actor boundaries freely. All work is off the main actor by construction.
public protocol TranscriptionProvider: Sendable {
    /// A stable identifier for logging/provenance (← `provider_name()`, provider.rs:72),
    /// e.g. "speechanalyzer" / "whisperkit". Persisted as `Meeting.transcriptionProvider`.
    var providerName: String { get }

    /// Is a usable model/engine available on THIS device right now? (← `is_model_loaded()`,
    /// provider.rs:66; for SpeechTranscriber this is `SpeechTranscriber.isAvailable` + installed
    /// assets — Probe.swift.) No fabrication: false when it genuinely can't run.
    func isAvailable() async -> Bool

    /// The model/locale currently in use, if resolvable (← `get_current_model()`, provider.rs:69).
    func currentModel() async -> String?

    /// RECORDED-FILE path (VERIFIED this stint). Transcribe a whole audio file to finalized
    /// segments. Mirrors the S2 spike's `analyzeSequence(from: AVAudioFile)` whole-file driver
    /// (Entry.swift:244) — no manual chunking. `language` is the optional hint (← the Rust
    /// `language: Option<String>` arg, provider.rs:61), incl. the "auto"/"auto-translate"/""
    /// sentinels (`STTLocale`). Throws `TranscriptionError` honestly on any failure
    /// (No-Fake-State).
    func transcribe(fileURL: URL, language: String?) async throws -> TranscriptionResult

    /// LIVE path (DESIGNED here, NOT verified this stint — Phase 3.2 feeds it). Consume a caller-
    /// owned async sequence of already-decoded PCM buffers and yield finalized segments as they
    /// finalize. Mirrors apple-helper's `analyzer.start(inputSequence:)` + `AnalyzerInput(buffer:)`
    /// (Transcribe.swift:165-170) generalized to a stream. The element is Apple's `AnalyzerInput`
    /// so capture never has to know STT internals; STT never touches the audio callback thread.
    func transcribe(
        liveInputs: some AsyncSequence<AnalyzerInput, Never> & Sendable,
        language: String?
    ) -> AsyncThrowingStream<TranscriptionSegment, Error>
}

/// The full result of a recorded-file transcription (← `TranscriptResult`, provider.rs:42, but
/// carrying real segments rather than one flat string). `fullText` is the segments joined,
/// matching the S2 rig's top-level `text` field (Entry.swift:253).
public struct TranscriptionResult: Sendable, Equatable {
    public var segments: [TranscriptionSegment]
    public var fullText: String // segments' text joined with a single space
    public var audioDurationSec: Double? // AVAudioFile length / sampleRate (Entry.swift:140)
    public var wordTimestampCount: Int // runs carrying `.audioTimeRange` (Entry.swift:210)

    public init(
        segments: [TranscriptionSegment],
        fullText: String,
        audioDurationSec: Double?,
        wordTimestampCount: Int
    ) {
        self.segments = segments
        self.fullText = fullText
        self.audioDurationSec = audioDurationSec
        self.wordTimestampCount = wordTimestampCount
    }
}

/// One finalized transcript segment (an `isFinal` `SpeechTranscriber.Result`, Entry.swift:200).
public struct TranscriptionSegment: Sendable, Equatable {
    public var text: String
    public var startSec: Double // CMTimeGetSeconds(result.range.start)
    public var endSec: Double // CMTimeGetSeconds(result.range.end)
    public var confidence: Double? // mean per-run confidence, nil if SDK gives none
    public var words: [WordTiming] // per-word timing (Parakeet had none — a gain)

    public init(
        text: String,
        startSec: Double,
        endSec: Double,
        confidence: Double?,
        words: [WordTiming]
    ) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.confidence = confidence
        self.words = words
    }
}

/// Per-word timing extracted from an AttributedString run's `.audioTimeRange` (Entry.swift:209).
public struct WordTiming: Sendable, Equatable {
    public var text: String
    public var startSec: Double
    public var endSec: Double
    public var confidence: Double?

    public init(text: String, startSec: Double, endSec: Double, confidence: Double?) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.confidence = confidence
    }
}

/// ← `TranscriptionError` (provider.rs:14), given matchable cases + three honest No-Fake-State cases.
public enum TranscriptionError: Error, Sendable, Equatable {
    case modelNotLoaded // ← ModelNotLoaded (provider.rs:15)
    case audioTooShort(samples: Int, minimum: Int) // ← AudioTooShort (provider.rs:16)
    case engineFailed(String) // ← EngineFailed (provider.rs:17)
    case unsupportedLanguage(String) // ← UnsupportedLanguage (provider.rs:18)
    case providerUnavailable(String) // NEW: engine/assets not on this device
    case assetsNotInstalled(locale: String) // NEW: locale resolvable but model not downloaded
    case audioDecodeFailed(String) // NEW: AVAudioFile could not open the file URL
}
