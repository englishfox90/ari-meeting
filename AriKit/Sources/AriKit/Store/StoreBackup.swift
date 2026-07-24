//
//  StoreBackup.swift — Layer 3 of the migration-safety hardening
//  (docs/plans/robust-migration-and-backup.md §3.1/§5).
//
//  Stateless SQLite snapshot machinery for the AriKit store. `StoreBackup` never touches
//  `FileManager` for path resolution/enumeration/deletion (arikit-store.md §2.2 — "the app
//  resolves paths; the Store never touches FileManager") — it takes explicit URLs handed in by
//  the app layer (`Ari/App/AppEnvironment.swift`) and only does SQLite work:
//
//  - `meetingCount(at:)` — the honest "is there anything worth protecting" signal. Row count on
//    the `meeting` anchor table, NOT file byte-size (a schema-only, freshly-migrated/erased DB is
//    still several KB of DDL, so size alone can't distinguish "0 meetings" from "22 meetings").
//  - `snapshot(from:to:)` — a single `VACUUM INTO` statement: a self-contained, defragmented
//    snapshot file with no `-wal`/`-shm` companions, capturing a consistent view including
//    committed WAL frames, in one statement. Chosen over a raw file copy (which would miss
//    uncheckpointed `-wal` frames on a `DatabasePool`/WAL-mode DB) and over GRDB's
//    `DatabaseReader.backup(to:)` (which needs a second live GRDB connection to receive into).
//  - `snapshotsToPrune(existing:now:keepWithin:)` — a PURE retention-policy function (no
//    FileManager, no I/O): given `(url, date)` tuples, returns which to delete. Always retains the
//    single most-recent snapshot regardless of age; deletes everything else older than
//    `keepWithin`.
//
//  All three functions are `static` over `Sendable` inputs (`URL`, `Date`) with no shared mutable
//  state, so `StoreBackup` is inherently `Sendable` as a plain `enum` namespace — no actor, no
//  `@unchecked Sendable`, no `nonisolated(unsafe)` needed. The app calls these from
//  `Task.detached` (off the main actor) per plan §4.
//
import Foundation
import GRDB

public enum StoreBackup {
    public enum Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        /// The source DB file couldn't be opened for reading (missing, corrupt, locked, etc.).
        case sourceUnreadable(underlying: String)
        /// `VACUUM INTO` refuses to write into a file that already exists — the caller must pass
        /// a not-yet-existing destination (uniquely timestamped filenames guarantee this).
        case destinationExists(URL)

        public var description: String {
            switch self {
            case let .sourceUnreadable(underlying):
                "store backup source unreadable: \(underlying)"
            case let .destinationExists(url):
                "store backup destination already exists: \(url.path)"
            }
        }
    }

    /// Row count of the `meeting` anchor table in an existing DB file, opened read-only. Returns
    /// `0` if the file exists but has no `meeting` table (a freshly-created/erased schema-only
    /// DB) — the app uses this to decide whether there's anything worth snapshotting, and never
    /// snapshots (or retains) an empty DB.
    ///
    /// Throws `Error.sourceUnreadable` if the file can't be opened at all (missing, corrupt,
    /// locked). Callers that want a "just tell me if it's non-empty" answer should catch that and
    /// treat it as "nothing to protect" (see `AppEnvironment.bootstrap()`'s best-effort wrapping).
    public static func meetingCount(at source: URL) throws -> Int {
        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: source.path, configuration: configuration)
        } catch {
            throw Error.sourceUnreadable(underlying: String(describing: error))
        }
        return try queue.read { db in
            guard try db.tableExists("meeting") else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting") ?? 0
        }
    }

    /// Snapshot `source` to `destination` (a NEW file) using SQLite's `VACUUM INTO`. Returns the
    /// `meeting` row count captured in the snapshot. Never mutates `source` — `VACUUM INTO` reads
    /// a consistent view (including committed WAL frames) without checkpointing or writing back to
    /// the source connection.
    ///
    /// The caller guarantees `destination` does not yet exist; `VACUUM INTO` throws a SQLite error
    /// in that case, which this surfaces as `Error.destinationExists` rather than the raw SQLite
    /// message.
    @discardableResult
    public static func snapshot(from source: URL, to destination: URL) throws -> Int {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw Error.destinationExists(destination)
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: source.path, configuration: configuration)
        } catch {
            throw Error.sourceUnreadable(underlying: String(describing: error))
        }
        // Escape the destination path for embedding into the VACUUM INTO SQL literal (single
        // quotes doubled, per SQLite string-literal escaping).
        let escapedPath = destination.path.replacingOccurrences(of: "'", with: "''")
        // `VACUUM INTO` cannot run inside a transaction — GRDB's `read`/`write` wrap their
        // closure in one, so this must go through `writeWithoutTransaction` even though the
        // statement itself only reads (the queue was opened read-only, so it still can't
        // accidentally mutate `source`).
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO '\(escapedPath)'")
        }
        return try meetingCount(at: destination)
    }

    /// PURE retention policy — no FileManager, no I/O. Given the existing snapshots (URL + mtime),
    /// return the URLs to delete: everything older than `keepWithin` seconds relative to `now`,
    /// EXCEPT the single most-recent snapshot, which is always retained regardless of age.
    public static func snapshotsToPrune(
        existing: [(url: URL, date: Date)],
        now: Date,
        keepWithin: TimeInterval
    ) -> [URL] {
        guard let newest = existing.max(by: { $0.date < $1.date }) else { return [] }
        return existing
            .filter { $0.url != newest.url && now.timeIntervalSince($0.date) > keepWithin }
            .map(\.url)
    }
}
