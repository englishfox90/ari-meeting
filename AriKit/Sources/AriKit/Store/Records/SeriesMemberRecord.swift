//
//  SeriesMemberRecord.swift — GRDB record for the `seriesMember` table (plan §4.7).
//
//  Store-internal only — a pure link row (composite PK `(seriesId, meetingId)`), no tombstone
//  column (§4.7 lists none; a meeting either is or isn't a member of a series, so membership is
//  added/removed directly via `SeriesRepository.addMember`/`removeMember`). The deferred
//  `SeriesMember` wire DTO (arikit-models.md §7.7) carries a denormalized `title` — that's a
//  view-layer aggregate, not part of this row.
//
import Foundation
import GRDB

struct SeriesMemberRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "seriesMember"

    var seriesId: String
    var meetingId: String
    var occurrenceTime: String?
    var linkSource: String?
    var createdAt: Date
}
