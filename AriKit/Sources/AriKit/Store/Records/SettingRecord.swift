//
//  SettingRecord.swift — GRDB record for the key-value `setting` table
//  (docs/plans/settings-ui.md §2.1).
//
//  Value stored as a plain `String` (SQLite has no typed columns to speak of); typed
//  accessors (`bool`/`int`) live on `SettingsRepository`, parsing at the boundary so this
//  record itself stays a dumb row mirror.
//
import Foundation
import GRDB

struct SettingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "setting"

    var key: String
    var value: String
    var updatedAt: Date
}
