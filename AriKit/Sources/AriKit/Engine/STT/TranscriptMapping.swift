//
//  TranscriptMapping.swift — TranscriptionSegment → Models.Transcript (plan §4 / Slice D).
//
//  Pure mapping, NOT a Store write: STT is stateless (§4), so this produces `Transcript` rows
//  in memory only — persisting them is the capture orchestrator's job (Phase 3.2) through
//  `TranscriptRepository`. Fresh `TranscriptID` per segment; `speakerId` stays `nil` here
//  (diarization is Phase 3.5 — the field resolves later via a voiceprint match, never guessed
//  here). Empty-text segments map to an empty-transcript row verbatim — silence is a real
//  outcome (No-Fake-State), not an error to paper over.
//
import Foundation

public enum TranscriptMapping {
    /// Maps one `TranscriptionSegment` to a `Transcript` row for `meetingId`.
    ///
    /// - `transcript` = `segment.text` verbatim (including empty string for silence).
    /// - `audioStartTime`/`audioEndTime` = `segment.startSec`/`segment.endSec`.
    /// - `duration` = `endSec - startSec`.
    /// - `speakerId` = `nil` (Phase 3.5 diarization resolves this later).
    /// - `timestamp` = an `MM:SS` display label derived from `segment.startSec`
    ///   (the recall chunker's expected label shape, ← `Chunker.swift`).
    public static func transcript(
        from segment: TranscriptionSegment,
        meetingId: MeetingID
    ) -> Transcript {
        Transcript(
            id: TranscriptID(UUID().uuidString),
            meetingId: meetingId,
            transcript: segment.text,
            timestamp: mmssLabel(forSeconds: segment.startSec),
            audioStartTime: segment.startSec,
            audioEndTime: segment.endSec,
            duration: segment.endSec - segment.startSec,
            speakerId: nil
        )
    }

    /// Maps a batch of segments to `Transcript` rows for `meetingId`, preserving order.
    /// Pure — does NOT write through `TranscriptRepository` (§4: the batch upsert hand-off is
    /// deferred to Phase 3.2).
    public static func transcripts(
        from segments: [TranscriptionSegment],
        meetingId: MeetingID
    ) -> [Transcript] {
        segments.map { transcript(from: $0, meetingId: meetingId) }
    }

    /// Renders a non-negative second offset as an `MM:SS` label (never hour-aware — matches the
    /// plain `mm:ss` convention used across existing `Transcript.timestamp` fixtures, e.g.
    /// `"00:05"`/`"00:30"`). Negative/invalid input floors to `0`, never fabricated.
    private static func mmssLabel(forSeconds seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
