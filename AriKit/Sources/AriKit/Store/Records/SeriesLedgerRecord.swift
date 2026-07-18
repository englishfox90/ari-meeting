//
//  SeriesLedgerRecord.swift — GRDB record for the `seriesLedger` table (plan §4.7).
//
//  Store-internal only. One row per `series` (the primary key is the FK itself). `ledgerVersion`
//  is `nil` when no ledger has ever been written — `SeriesRepository` is the only writer, and it
//  always keeps exactly one `seriesLedger` row alongside its `series` row (created lazily on the
//  first `upsert`/`updateLedger`, per that repository's header).
//
import Foundation
import GRDB

struct SeriesLedgerRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "seriesLedger"

    var seriesId: String
    var ledgerMarkdown: String?
    var structuredJson: String?
    var updatedFromMeetingId: String?
    var ledgerVersion: Int?
    var createdAt: Date
    var updatedAt: Date
}
