//
//  CalendarSyncSettingRecord.swift — GRDB record for the `calendarSyncSetting` table (plan §4.8).
//
//  Store-internal only — config/selection state, not a synced text record. No dedicated public
//  domain type: the Rust wire `CalendarInfo` DTO was deliberately deferred as a view-layer
//  aggregate (arikit-models.md §7.7), so `CalendarEventRepository` exposes this table's fields
//  as plain value-in/value-out parameters rather than inventing that DTO here.
//
import Foundation
import GRDB

struct CalendarSyncSettingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "calendarSyncSetting"

    var calendarId: String
    var calendarTitle: String?
    var color: String?
    var selected: Bool
}
