//
//  SettingsRepository.swift — the ONLY way feature code touches the `setting` table
//  (docs/plans/settings-ui.md §2.1).
//
//  Per-key rows (not the Rust wide single-row shape): an unknown/absent key returns `nil` from
//  every typed accessor — this repository NEVER fabricates a default. The documented default is
//  the CALLER's job to apply (`SettingsViewModel`'s published prefs each carry their own honest
//  default constant, applied only when the store returns `nil`).
//
import Foundation
import GRDB

public struct SettingsRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// The raw stored string, or `nil` if the key has never been set.
    public func string(forKey key: SettingKey) async throws -> String? {
        try await dbWriter.read { db in
            try SettingRecord.fetchOne(db, key: key.rawValue)?.value
        }
    }

    /// Parses the stored string as a bool (`"true"`/`"false"`). Absent or unparsable → `nil`,
    /// never a fabricated default.
    public func bool(forKey key: SettingKey) async throws -> Bool? {
        guard let raw = try await string(forKey: key) else { return nil }
        switch raw {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Parses the stored string as an `Int`. Absent or unparsable → `nil`.
    public func int(forKey key: SettingKey) async throws -> Int? {
        guard let raw = try await string(forKey: key) else { return nil }
        return Int(raw)
    }

    /// Insert-or-update, stamping `updatedAt = now`.
    public func setString(_ value: String, forKey key: SettingKey, now: Date = Date()) async throws {
        try await dbWriter.write { db in
            try SettingRecord(key: key.rawValue, value: value, updatedAt: now).save(db)
        }
    }

    public func setBool(_ value: Bool, forKey key: SettingKey, now: Date = Date()) async throws {
        try await setString(value ? "true" : "false", forKey: key, now: now)
    }

    public func setInt(_ value: Int, forKey key: SettingKey, now: Date = Date()) async throws {
        try await setString(String(value), forKey: key, now: now)
    }

    /// Deletes the row entirely — a hard delete (config, not synced content; no tombstone, mirrors
    /// `calendarSyncSetting`).
    public func remove(forKey key: SettingKey) async throws {
        try await dbWriter.write { db in
            _ = try SettingRecord.deleteOne(db, key: key.rawValue)
        }
    }

    /// Every stored key/value pair, keyed by the raw `SettingKey.rawValue` string.
    public func all() async throws -> [String: String] {
        try await dbWriter.read { db in
            let records = try SettingRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.value) })
        }
    }

    /// Live updates to one key's string value, via GRDB `ValueObservation`
    /// (mirrors `MeetingRepository.observeAll()`).
    public func observeString(forKey key: SettingKey) -> AsyncStream<String?> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in
            try SettingRecord.fetchOne(db, key: key.rawValue)?.value
        }
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: dbWriter) {
                        continuation.yield(value)
                    }
                } catch {
                    // See MeetingRepository.observeAll(): a failure ends the stream.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
