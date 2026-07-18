//
//  LegacyDatabaseReader.swift — a read-only connection to the legacy Rust-engine SQLite file
//  (plan §5.1).
//
//  A SECOND, independent GRDB connection on a DIFFERENT file than the one `AppDatabase` owns —
//  never a writer, so single-owner (plan principle 3) holds. Read-only mode never checkpoints or
//  writes, so it's safe to open alongside a still-running Tauri app during the transition window
//  (SQLite readers don't block a WAL writer).
//
//  `Store` never hardcodes or discovers this path — the caller passes the source `URL` in. The
//  legacy file lives at `~/Library/Application Support/com.meetily.ai/meeting_minutes.db`
//  (confirmed in `frontend/src-tauri/src/database/manager.rs`); the app-target caller resolves
//  that path, never this module.
//
//  No migration is run against this connection — the legacy schema is read as-is. The 25 Rust
//  sqlx migrations are strictly additive, so any legacy file on disk carries the full final-shape
//  column set documented in plan §5.2's mapping table.
//
import Foundation
import GRDB

/// Thrown when the legacy source file doesn't exist at the given path (plan §5.6 — "legacy file
/// missing" is a named failure mode, not a crash).
enum LegacyReaderError: Error, Sendable, Equatable, CustomStringConvertible {
    case sourceNotFound(path: String)

    var description: String {
        switch self {
        case let .sourceNotFound(path):
            "legacy database not found at \(path)"
        }
    }
}

public struct LegacyDatabaseReader: Sendable {
    /// Module-internal (not `public`) — only `LegacyDatabaseImporter` reads through this
    /// connection; nothing outside `Store` ever sees a raw GRDB handle.
    let dbQueue: DatabaseQueue

    /// Opens the legacy file at `sourceURL` **read-only**. Throws `LegacyReaderError
    /// .sourceNotFound` if nothing exists at that path (checked explicitly rather than letting
    /// SQLite's read-only open surface an opaque OS error) — no file is ever created as a side
    /// effect of a failed open.
    public init(sourceURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LegacyReaderError.sourceNotFound(path: sourceURL.path)
        }
        var configuration = Configuration()
        configuration.readonly = true
        dbQueue = try DatabaseQueue(path: sourceURL.path, configuration: configuration)
    }
}
