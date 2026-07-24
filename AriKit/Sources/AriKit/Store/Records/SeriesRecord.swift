//
//  SeriesRecord.swift — GRDB record for the `series` table (plan §4.7).
//
//  Store-internal only — `SeriesRepository` translates to/from the public
//  `AriKit.Models.Series` value type, reconciling this row with the separate `seriesLedger` row
//  (`ledgerMarkdown`/`ledgerVersion` live there, not here — the domain type flattens what the
//  schema keeps split).
//
//  ⚠️ `templateId` exists as a schema column (§4.7) but `Series` (AriKit.Models) carries no
//  `templateId` field yet — the same documented gap as `Meeting.templateId`
//  (`Records/MeetingRecord.swift`). Always persisted as `NULL` here, not part of the
//  `asModel()`/`init(_:)` round trip; wire it up when template selection lands.
//
import Foundation
import GRDB

struct SeriesRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "series"

    var id: String
    var seriesKey: String?
    var title: String
    var detectedType: String?
    var cadence: String?
    var ownerPersonId: String?
    var templateId: String?
    /// Consent memory for series auto-detection (calendar-series-intelligence plan §2.1) —
    /// `'ask'` | `'always'` | `'never'`. Store-internal only, same documented gap as `templateId`
    /// above (not yet on `AriKit.Models.Series`); `SeriesRepository.upsert(_:)` preserves it
    /// across a plain `Series` upsert rather than resetting it to the default.
    var autoAddMode: String
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}

extension SeriesRecord {
    init(_ series: Series) {
        id = series.id.rawValue
        seriesKey = series.seriesKey
        title = series.title
        detectedType = series.detectedType
        cadence = series.cadence
        ownerPersonId = series.ownerPersonId?.rawValue
        templateId = nil
        autoAddMode = "ask"
        createdAt = series.createdAt
        updatedAt = series.updatedAt
        isDeleted = false
        deletedAt = nil
    }

    /// See file header: `ledgerMarkdown`/`ledgerVersion` live on the separate `seriesLedger`
    /// table — the repository supplies both, read live from that row.
    func asModel(ledgerMarkdown: String?, ledgerVersion: Int?) -> Series {
        Series(
            id: SeriesID(id),
            title: title,
            seriesKey: seriesKey,
            detectedType: detectedType,
            cadence: cadence,
            ownerPersonId: ownerPersonId.map { PersonID($0) },
            ledgerMarkdown: ledgerMarkdown,
            ledgerVersion: ledgerVersion,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
