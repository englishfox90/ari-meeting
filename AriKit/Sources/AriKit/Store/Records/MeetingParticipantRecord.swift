//
//  MeetingParticipantRecord.swift — GRDB record for the `meetingParticipant` table (Phase 3.4
//  Track H, `arikit-engine-extras.md` §2.3/§6-5).
//
//  Store-internal only — a pure link row (composite PK `(meetingId, personId)`), no tombstone
//  column (mirrors `SeriesMemberRecord`'s precedent: a person either is or isn't a participant, so
//  membership is added/removed directly via `PersonRepository.addParticipant`/`removeParticipant`).
//  No public wire DTO wraps this row — `PersonRepository.participants(inMeeting:)` returns plain
//  `[Person]`, matching Rust's `list_participants` return shape.
//
import Foundation
import GRDB

struct MeetingParticipantRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meetingParticipant"

    var meetingId: String
    var personId: String
    var linkSource: String?
    var createdAt: Date
}
