//
//  CMTimeMapping.swift — CMTime→seconds guard + per-run word/confidence extraction
//  (plan §2.2/§5, ← Entry.swift:97-100,199-214).
//
//  Pure and side-effect free — no live model needed. `extractWordTimings(from:)` hand-walks an
//  `AttributedString`'s runs pulling `.audioTimeRange`/`.transcriptionConfidence` (the same
//  `AttributeScopes.SpeechAttributes` dynamic-member attributes `SpeechTranscriber.Result.text`
//  carries) into `[WordTiming]` + a mean confidence — exactly the S2 driver's collector loop,
//  factored out so it's testable against a hand-synthesized `AttributedString` with no live
//  transcription session.
//
import CoreMedia
import Foundation
import Speech

public enum CMTimeMapping {
    /// `CMTime` → seconds, guarding invalid/indefinite times to `0` rather than propagating NaN/inf
    /// (← Entry.swift:97-100 / Transcribe.swift's discipline of never inventing a number).
    public static func seconds(_ time: CMTime) -> Double {
        guard time.isValid, !time.isIndefinite else { return 0 }
        return CMTimeGetSeconds(time)
    }

    /// Walks `text`'s runs, extracting one `WordTiming` per run that carries an `.audioTimeRange`
    /// (runs with no audio time range — e.g. pure formatting glue — are skipped for word timing,
    /// mirroring `Entry.swift:205-212`'s `if run.audioTimeRange != nil { wordTimestampCount += 1 }`
    /// gate), plus the mean `.transcriptionConfidence` across every run that carried one (`nil` if
    /// none did — never fabricated, ← Entry.swift:213).
    public static func extractWordTimings(
        from text: AttributedString
    ) -> (words: [WordTiming], meanConfidence: Double?) {
        var words: [WordTiming] = []
        var confidences: [Double] = []

        for run in text.runs {
            let confidence = run.transcriptionConfidence
            if let confidence {
                confidences.append(confidence)
            }
            if let range = run.audioTimeRange {
                let runText = String(text[run.range].characters)
                words.append(WordTiming(
                    text: runText,
                    startSec: seconds(range.start),
                    endSec: seconds(range.end),
                    confidence: confidence
                ))
            }
        }

        let meanConfidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        return (words, meanConfidence)
    }
}
