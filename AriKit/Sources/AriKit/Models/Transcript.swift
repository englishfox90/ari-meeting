//
//  Transcript.swift — one transcript segment (← Rust `Transcript`, database/models.rs:30).
//
//  `timestamp` stays `String` (plan decision 0.3): its representation (RFC3339 instant vs.
//  display label) is unconfirmed, so it is not mis-typed as `Date`. The recording-relative
//  audio offsets (`audioStartTime`/`audioEndTime`/`duration`) are `Double` seconds, not dates.
//  `speakerId` is the F1 diarization result — `nil` until a voiceprint match resolves it.
//
//  ⚠️ Wire surface: the Rust `Transcript` has no `#[serde(rename_all)]`; the engine emits
//  snake_case (`audio_start_time`, `speaker_id`, …), so this camelCase-native type needs a
//  snake→camel adapter at the Store/Engine seam to decode raw engine JSON (plan §7.7).
//
import Foundation

/// Typed identifier for a `Transcript` segment (plan §7.4).
public typealias TranscriptID = Identifier<Transcript>

public struct Transcript: Codable, Hashable, Sendable, Identifiable {
    public var id: TranscriptID
    public var meetingId: MeetingID
    public var transcript: String
    /// Segment timestamp label; representation unconfirmed, kept as `String` (plan decision 0.3).
    public var timestamp: String
    public var summary: String?
    public var actionItems: String?
    public var keyPoints: String?
    /// Recording-relative start offset, seconds.
    public var audioStartTime: Double?
    /// Recording-relative end offset, seconds.
    public var audioEndTime: Double?
    /// Segment duration, seconds.
    public var duration: Double?
    /// Resolved speaker for this segment (F1); `nil` until diarization matches a voiceprint.
    public var speakerId: SpeakerID?

    public init(
        id: TranscriptID,
        meetingId: MeetingID,
        transcript: String,
        timestamp: String,
        summary: String? = nil,
        actionItems: String? = nil,
        keyPoints: String? = nil,
        audioStartTime: Double? = nil,
        audioEndTime: Double? = nil,
        duration: Double? = nil,
        speakerId: SpeakerID? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.transcript = transcript
        self.timestamp = timestamp
        self.summary = summary
        self.actionItems = actionItems
        self.keyPoints = keyPoints
        self.audioStartTime = audioStartTime
        self.audioEndTime = audioEndTime
        self.duration = duration
        self.speakerId = speakerId
    }
}
