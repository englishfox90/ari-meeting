//
//  StoreBackupTests.swift — proving the Layer-3 pre-migration snapshot machinery works and its
//  pure retention policy holds (docs/plans/robust-migration-and-backup.md §7, tests 5–8).
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("StoreBackup — snapshot + retention policy")
struct StoreBackupTests {
    private func tempFileURL(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("store-backup-\(name)")
            .appendingPathExtension("sqlite")
    }

    /// A minimal migrated DB with N `meeting` rows (+ one `transcript` row each, FK'd to the
    /// meeting) at `url`.
    private func makeSourceDatabase(at url: URL, meetingCount: Int) throws {
        let pool = try DatabasePool(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_baseline") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
            }
            try db.create(table: "transcript") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text).notNull().references("meeting", onDelete: .cascade)
                t.column("body", .text).notNull()
            }
        }
        try migrator.migrate(pool)
        try pool.write { db in
            for index in 0..<meetingCount {
                let meetingId = "m\(index)"
                try db.execute(
                    sql: "INSERT INTO meeting (id, title) VALUES (?, ?)",
                    arguments: [meetingId, "Meeting \(index)"]
                )
                try db.execute(
                    sql: "INSERT INTO transcript (id, meetingId, body) VALUES (?, ?, ?)",
                    arguments: ["t\(index)", meetingId, "hello \(index)"]
                )
            }
        }
        // Release the pool's connections so the file isn't held open by this process during the
        // snapshot (mirrors how the real pre-migration backup runs strictly before
        // `AppDatabase.makeShared` opens its own pool).
    }

    @Test("Test 5 — snapshot captures all rows and never mutates the source")
    func test_snapshotCapturesAllRows() throws {
        let source = tempFileURL("source")
        let destination = tempFileURL("dest")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try makeSourceDatabase(at: source, meetingCount: 5)
        let sourceBytesBefore = try Data(contentsOf: source)

        let capturedCount = try StoreBackup.snapshot(from: source, to: destination)
        #expect(capturedCount == 5)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try StoreBackup.meetingCount(at: destination) == 5)

        let sourceBytesAfter = try Data(contentsOf: source)
        #expect(sourceBytesBefore == sourceBytesAfter)
    }

    @Test("Test 6 — meetingCount is 0 for a fresh/empty migrated DB; nonexistent path throws")
    func test_meetingCountZeroForFreshDb() throws {
        let url = tempFileURL("empty")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeSourceDatabase(at: url, meetingCount: 0)
        #expect(try StoreBackup.meetingCount(at: url) == 0)

        let missing = tempFileURL("does-not-exist")
        #expect(throws: StoreBackup.Error.self) {
            try StoreBackup.meetingCount(at: missing)
        }
    }

    @Test("Test 7 — prune keeps everything within 3 days, and always keeps the single newest")
    func test_pruneKeepsWithin3DaysAndAlwaysNewest() {
        let now = Date()
        let day: TimeInterval = 24 * 3600
        let keepWithin: TimeInterval = 3 * day

        // The newest entry, chronologically — but well older than the 3-day window. Must always
        // survive pruning regardless of its age.
        let newestButStale = (
            url: URL(fileURLWithPath: "/tmp/newest-but-stale.sqlite"),
            date: now.addingTimeInterval(-1 * day) // most recent of the four
        )
        let old1 = (
            url: URL(fileURLWithPath: "/tmp/old1.sqlite"),
            date: now.addingTimeInterval(-4 * day)
        )
        let old2 = (
            url: URL(fileURLWithPath: "/tmp/old2.sqlite"),
            date: now.addingTimeInterval(-5 * day)
        )
        let evenOlder = (
            url: URL(fileURLWithPath: "/tmp/even-older.sqlite"),
            date: now.addingTimeInterval(-10 * day)
        )

        let existing = [newestButStale, old1, old2, evenOlder]
        let toPrune = StoreBackup.snapshotsToPrune(existing: existing, now: now, keepWithin: keepWithin)

        // Everything older than 3 days is pruned, except the newest of the set.
        #expect(Set(toPrune) == Set([old1.url, old2.url, evenOlder.url]))
        #expect(!toPrune.contains(newestButStale.url))
    }

    @Test("Test 7b — the newest snapshot is retained even if it is itself older than 3 days")
    func test_pruneAlwaysKeepsNewestEvenIfOld() {
        let now = Date()
        let day: TimeInterval = 24 * 3600
        let onlyEntry = (url: URL(fileURLWithPath: "/tmp/only.sqlite"), date: now.addingTimeInterval(-10 * day))

        let toPrune = StoreBackup.snapshotsToPrune(existing: [onlyEntry], now: now, keepWithin: 3 * day)
        #expect(toPrune.isEmpty)
    }

    @Test("Test 8 — the snapshot is self-contained; no -wal/-shm companion is needed to reopen it")
    func test_snapshotIsSelfContainedNoWal() throws {
        let source = tempFileURL("source8")
        let destination = tempFileURL("dest8")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try makeSourceDatabase(at: source, meetingCount: 3)
        try StoreBackup.snapshot(from: source, to: destination)

        let walPath = destination.path + "-wal"
        let shmPath = destination.path + "-shm"
        #expect(!FileManager.default.fileExists(atPath: walPath))
        #expect(!FileManager.default.fileExists(atPath: shmPath))

        // Reopen read-only with no companion files present and confirm the data is intact.
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: destination.path, configuration: configuration)
        let count = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting") ?? 0 }
        #expect(count == 3)
    }
}
