//
//  TranscriptRecord.swift — GRDB record for the `transcript` table (plan §4.2).
//
//  Store-internal only — `TranscriptRepository` translates to/from the public
//  `AriKit.Models.Transcript` value type.
//
//  ⚠️ `Transcript.summary`/`.actionItems`/`.keyPoints` (Models, pre-chunking-era fields) are
//  deliberately NOT persisted (plan §4.2/§4.10 — superseded by the dedicated `summary` table,
//  step 3): they round-trip to `nil` through the store, even if the in-memory model carried a
//  value before `upsert`.
//
import Foundation
import GRDB

struct TranscriptRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "transcript"

    var id: String
    var meetingId: String
    var transcript: String
    var timestamp: String
    var audioStartTime: Double?
    var audioEndTime: Double?
    var duration: Double?
    var speakerId: String?
    var isDeleted: Bool
    var deletedAt: Date?
}

extension TranscriptRecord {
    init(_ transcript: Transcript) {
        id = transcript.id.rawValue
        meetingId = transcript.meetingId.rawValue
        self.transcript = transcript.transcript
        timestamp = transcript.timestamp
        audioStartTime = transcript.audioStartTime
        audioEndTime = transcript.audioEndTime
        duration = transcript.duration
        speakerId = transcript.speakerId?.rawValue
        isDeleted = false
        deletedAt = nil
    }

    func asModel() -> Transcript {
        Transcript(
            id: TranscriptID(id),
            meetingId: MeetingID(meetingId),
            transcript: transcript,
            timestamp: timestamp,
            audioStartTime: audioStartTime,
            audioEndTime: audioEndTime,
            duration: duration,
            speakerId: speakerId.map { SpeakerID($0) }
        )
    }
}
