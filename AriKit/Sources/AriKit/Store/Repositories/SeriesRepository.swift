//
//  SeriesRepository.swift — the ONLY way feature code touches the `series`, `seriesLedger`, and
//  `seriesMember` tables (plan §2.2, §10 step 6).
//
//  The domain `Series` flattens what the schema keeps split (plan §4.7): every read joins the
//  `series` row with its `seriesLedger` row (`Self.hydrate`, mirroring `ProfileFactRepository`'s
//  read-time composition) to populate `ledgerMarkdown`/`ledgerVersion`. `upsert(_:)` keeps exactly
//  one `seriesLedger` row per series — creating it lazily on first write, and preserving
//  `structuredJson`/`updatedFromMeetingId` (fields the domain type doesn't carry) across a plain
//  `upsert` by fetch-then-mutate rather than blind overwrite.
//
//  Membership (`seriesMember`) is NOT surfaced on `Series` itself — the richer `SeriesMember` wire
//  DTO (denormalized `title`, `occurrenceTime`) was deliberately deferred (arikit-models.md §7.7),
//  so this repository exposes membership as plain `MeetingID` operations instead of inventing
//  that DTO here.
//
import Foundation
import GRDB

public struct SeriesRepository: Sendable {
    let dbWriter: any DatabaseWriter

    public func all(includingDeleted: Bool = false) async throws -> [Series] {
        try await dbWriter.read { db in
            var request = SeriesRecord.order(Column("createdAt").desc)
            if !includingDeleted {
                request = request.filter(Column("isDeleted") == false)
            }
            return try request.fetchAll(db).map { try Self.hydrate($0, db: db) }
        }
    }

    /// List-row summaries: each series with its member count and most-recent member date, ordered
    /// alphabetically by title (case-insensitive). Deleted series are excluded; deleted meetings
    /// don't count toward `meetingCount`/`lastMeetingTime`. This is the join-aggregate read the
    /// domain `Series` type intentionally can't express (see `SeriesSummary`).
    public func allSummaries() async throws -> [SeriesSummary] {
        try await dbWriter.read { db in try Self.fetchSummaries(db) }
    }

    public func observeSummaries() -> AsyncStream<[SeriesSummary]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db in try Self.fetchSummaries(db) }
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: dbWriter) {
                        continuation.yield(value)
                    }
                } catch {
                    // See observeAll(): a failure ends the stream.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func fetchSummaries(_ db: Database) throws -> [SeriesSummary] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT s.id AS id, s.title AS title, s.detectedType AS detectedType, s.cadence AS cadence,
               COUNT(m.id) AS meetingCount, MAX(m.createdAt) AS lastMeetingTime
        FROM series s
        LEFT JOIN seriesMember sm ON sm.seriesId = s.id
        LEFT JOIN meeting m ON m.id = sm.meetingId AND m.isDeleted = 0
        WHERE s.isDeleted = 0
        GROUP BY s.id
        ORDER BY s.title COLLATE NOCASE ASC
        """)
        return rows.map { row in
            SeriesSummary(
                id: SeriesID(row["id"]),
                title: row["title"],
                detectedType: row["detectedType"],
                cadence: row["cadence"],
                meetingCount: row["meetingCount"],
                lastMeetingTime: row["lastMeetingTime"]
            )
        }
    }

    public func find(_ id: SeriesID) async throws -> Series? {
        try await dbWriter.read { db in
            guard let record = try SeriesRecord.fetchOne(db, key: id.rawValue) else { return nil }
            return try Self.hydrate(record, db: db)
        }
    }

    /// Insert-or-update the `series` row, keyed on the stable `SeriesID` primary key, and keep
    /// exactly one `seriesLedger` row in step with `ledgerMarkdown`/`ledgerVersion` (see file
    /// header — `structuredJson`/`updatedFromMeetingId` on an existing ledger row are preserved,
    /// never wiped by a plain `Series` upsert).
    public func upsert(_ series: Series) async throws {
        try await dbWriter.write { db in
            try SeriesRecord(series).save(db)

            // Only touch the ledger when the incoming Series actually carries ledger content. A
            // plain Series upsert (a rename, or the importer's series pass which always maps the
            // ledger fields to nil — the follow-on ledger pass fills them via updateLedger) must
            // NOT wipe or reset a ledger owned by updateLedger or a live post-cutover edit. Ledger
            // mutations go through updateLedger; upsert(Series) never clears one.
            guard series.ledgerMarkdown != nil || series.ledgerVersion != nil else { return }

            var ledger = try SeriesLedgerRecord.fetchOne(db, key: series.id.rawValue) ??
                SeriesLedgerRecord(
                    seriesId: series.id.rawValue,
                    ledgerMarkdown: nil,
                    structuredJson: nil,
                    updatedFromMeetingId: nil,
                    ledgerVersion: nil,
                    createdAt: series.updatedAt,
                    updatedAt: series.updatedAt
                )
            ledger.ledgerMarkdown = series.ledgerMarkdown
            ledger.ledgerVersion = series.ledgerVersion
            ledger.updatedAt = series.updatedAt
            try ledger.save(db)
        }
    }

    /// Fine-grained ledger update — the fields `Series` doesn't carry (`structuredJson`,
    /// `updatedFromMeetingId`). Creates the `seriesLedger` row if it doesn't exist yet (the
    /// `series` row must already exist — `seriesId` is an FK).
    public func updateLedger(
        seriesId: SeriesID,
        ledgerMarkdown: String?,
        structuredJson: String?,
        updatedFromMeetingId: MeetingID?,
        ledgerVersion: Int?,
        at date: Date
    ) async throws {
        try await dbWriter.write { db in
            if var ledger = try SeriesLedgerRecord.fetchOne(db, key: seriesId.rawValue) {
                ledger.ledgerMarkdown = ledgerMarkdown
                ledger.structuredJson = structuredJson
                ledger.updatedFromMeetingId = updatedFromMeetingId?.rawValue
                ledger.ledgerVersion = ledgerVersion
                ledger.updatedAt = date
                try ledger.update(db)
            } else {
                try SeriesLedgerRecord(
                    seriesId: seriesId.rawValue,
                    ledgerMarkdown: ledgerMarkdown,
                    structuredJson: structuredJson,
                    updatedFromMeetingId: updatedFromMeetingId?.rawValue,
                    ledgerVersion: ledgerVersion,
                    createdAt: date,
                    updatedAt: date
                ).insert(db)
            }
        }
    }

    /// Tombstone — sets `isDeleted`/`deletedAt` on the `series` row only, never a hard `DELETE`.
    /// The `seriesLedger` row is left as-is (it has no tombstone of its own, plan §4.7).
    public func softDelete(_ id: SeriesID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var record = try SeriesRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    public func observeAll() -> AsyncStream<[Series]> {
        let dbWriter = dbWriter
        let observation = ValueObservation.tracking { db -> [Series] in
            let records = try SeriesRecord
                .filter(Column("isDeleted") == false)
                .order(Column("createdAt").desc)
                .fetchAll(db)
            return try records.map { try Self.hydrate($0, db: db) }
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

    // MARK: - Membership (`seriesMember`)

    /// The meetings belonging to a series, in the order they were added.
    public func meetingIds(inSeries seriesId: SeriesID) async throws -> [MeetingID] {
        try await dbWriter.read { db in
            try SeriesMemberRecord
                .filter(Column("seriesId") == seriesId.rawValue)
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { MeetingID($0.meetingId) }
        }
    }

    /// The series a meeting belongs to, oldest membership first. The reverse of
    /// `meetingIds(inSeries:)` — the "which series is this meeting in?" read the meeting-detail
    /// "Add to series" control needs. The schema permits multiple memberships (composite-PK link
    /// table), so this honestly returns all of them rather than assuming one.
    public func seriesIds(forMeeting meetingId: MeetingID) async throws -> [SeriesID] {
        try await dbWriter.read { db in
            try SeriesMemberRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { SeriesID($0.seriesId) }
        }
    }

    /// Insert-or-update a series/meeting membership link.
    public func addMember(
        seriesId: SeriesID,
        meetingId: MeetingID,
        occurrenceTime: String? = nil,
        linkSource: String? = nil,
        at date: Date = Date()
    ) async throws {
        try await dbWriter.write { db in
            try SeriesMemberRecord(
                seriesId: seriesId.rawValue,
                meetingId: meetingId.rawValue,
                occurrenceTime: occurrenceTime,
                linkSource: linkSource,
                createdAt: date
            ).save(db)
        }
    }

    /// A genuine hard delete of the link row — no tombstone column exists on `seriesMember`
    /// (plan §4.7 lists none for this table).
    @discardableResult
    public func removeMember(seriesId: SeriesID, meetingId: MeetingID) async throws -> Bool {
        try await dbWriter.write { db in
            try SeriesMemberRecord.deleteOne(
                db,
                key: ["seriesId": seriesId.rawValue, "meetingId": meetingId.rawValue]
            )
        }
    }

    // MARK: - Read-time reconciliation (series ⊕ seriesLedger — plan §4.7, No-Fake-State)

    private static func hydrate(_ record: SeriesRecord, db: Database) throws -> Series {
        let ledger = try SeriesLedgerRecord.fetchOne(db, key: record.id)
        return record.asModel(
            ledgerMarkdown: ledger?.ledgerMarkdown,
            ledgerVersion: ledger?.ledgerVersion
        )
    }
}
