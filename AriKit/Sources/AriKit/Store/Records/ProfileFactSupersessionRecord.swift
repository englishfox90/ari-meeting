//
//  ProfileFactSupersessionRecord.swift — GRDB record for the `profileFactSupersession` table
//  (docs/plans/person-fact-consolidation.md §4.2).
//
//  Store-internal only — a pure many-old-to-one-new join row (composite PK
//  `(newFactId, oldFactId)`, both FK `ON DELETE CASCADE`), no tombstone column (mirrors
//  `MeetingParticipantRecord`'s precedent: a supersession link is added once by
//  `ProfileFactRepository.recordSupersession` and never mutated in place). No public wire DTO
//  wraps this row — `ProfileFactRepository.oldFactIds(supersededBy:)` returns plain
//  `[ProfileFactID]`.
//
import Foundation
import GRDB

struct ProfileFactSupersessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "profileFactSupersession"

    var newFactId: String
    var oldFactId: String
}
