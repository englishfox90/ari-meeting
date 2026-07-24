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

/// The result of `SeriesRepository.findByKeyIncludingDeleted(_:)` — `isDeleted`/`autoAddMode` are
/// Store-internal (not on the domain `Series` type), so `SeriesDetector` reads them through this
/// small lookup value instead (calendar-series-intelligence plan §2.1).
struct SeriesKeyLookup: Sendable, Equatable {
    let id: SeriesID
    let isDeleted: Bool
    let autoAddMode: String
}

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
        // `sm.linkSource <> 'suggested'` excludes pending-consent memberships (calendar-series-
        // intelligence plan §2.1) — counts/last-meeting-time shown in UI are accepted members only.
        let rows = try Row.fetchAll(db, sql: """
        SELECT s.id AS id, s.title AS title, s.detectedType AS detectedType, s.cadence AS cadence,
               COUNT(m.id) AS meetingCount, MAX(m.createdAt) AS lastMeetingTime
        FROM series s
        LEFT JOIN seriesMember sm ON sm.seriesId = s.id
            AND (sm.linkSource IS NULL OR sm.linkSource <> 'suggested')
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

    /// A series row keyed by its stable recurrence key, INCLUDING tombstoned rows — `seriesKey`
    /// is UNIQUE, so a tombstoned holder must stay visible to `SeriesDetector` (it must honor the
    /// user's deletion rather than hit the UNIQUE constraint trying to create a new row for the
    /// same key). `isDeleted`/`autoAddMode` are Store-internal, so this returns a small lookup
    /// value rather than adding either to the domain `Series` type (plan §2.1).
    func findByKeyIncludingDeleted(_ seriesKey: String) async throws -> SeriesKeyLookup? {
        try await dbWriter.read { db in
            guard let record = try SeriesRecord
                .filter(Column("seriesKey") == seriesKey)
                .fetchOne(db)
            else { return nil }
            return SeriesKeyLookup(
                id: SeriesID(record.id),
                isDeleted: record.isDeleted,
                autoAddMode: record.autoAddMode
            )
        }
    }

    /// Creates a brand-new series for a detected recurrence key (`SeriesDetector`'s find-or-create
    /// path, plan §2.2) — `autoAddMode` starts at `'ask'`, no ledger row. Callers must have
    /// already confirmed no live or tombstoned row holds this key
    /// (`findByKeyIncludingDeleted`) — `seriesKey` is UNIQUE.
    func createSeriesForDetection(seriesKey: String, title: String, at date: Date) async throws -> SeriesID {
        let id = SeriesID(UUID().uuidString)
        try await dbWriter.write { db in
            try SeriesRecord(
                id: id.rawValue,
                seriesKey: seriesKey,
                title: title,
                detectedType: nil,
                cadence: nil,
                ownerPersonId: nil,
                templateId: nil,
                autoAddMode: "ask",
                createdAt: date,
                updatedAt: date,
                isDeleted: false,
                deletedAt: nil
            ).insert(db)
        }
        return id
    }

    /// Insert-or-update the `series` row, keyed on the stable `SeriesID` primary key, and keep
    /// exactly one `seriesLedger` row in step with `ledgerMarkdown`/`ledgerVersion` (see file
    /// header — `structuredJson`/`updatedFromMeetingId` on an existing ledger row are preserved,
    /// never wiped by a plain `Series` upsert).
    public func upsert(_ series: Series) async throws {
        try await dbWriter.write { db in
            var record = SeriesRecord(series)
            // `autoAddMode` is Store-internal (not on the domain `Series` type, same documented
            // gap as `templateId`) — preserve whatever the row already carries across a plain
            // `Series` upsert (rename, importer pass) rather than resetting consent state back to
            // the record's default 'ask'. New rows keep the init default.
            if let existing = try SeriesRecord.fetchOne(db, key: series.id.rawValue) {
                record.autoAddMode = existing.autoAddMode
            }
            try record.save(db)

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

    /// The meetings belonging to a series, in the order they were added. Excludes `'suggested'`
    /// (pending-consent) memberships — calendar-series-intelligence plan §2.1: suggestions are
    /// invisible to series *content* semantics until confirmed.
    public func meetingIds(inSeries seriesId: SeriesID) async throws -> [MeetingID] {
        try await dbWriter.read { db in
            try SeriesMemberRecord
                .filter(Column("seriesId") == seriesId.rawValue)
                .filter(Column("linkSource") == nil || Column("linkSource") != "suggested")
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { MeetingID($0.meetingId) }
        }
    }

    /// The series a meeting belongs to, oldest membership first. The reverse of
    /// `meetingIds(inSeries:)` — the "which series is this meeting in?" read the meeting-detail
    /// "Add to series" control needs. The schema permits multiple memberships (composite-PK link
    /// table), so this honestly returns all of them rather than assuming one. Excludes
    /// `'suggested'` memberships (plan §2.1) — use `suggestedSeriesIds(forMeeting:)` for those.
    public func seriesIds(forMeeting meetingId: MeetingID) async throws -> [SeriesID] {
        try await dbWriter.read { db in
            try SeriesMemberRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .filter(Column("linkSource") == nil || Column("linkSource") != "suggested")
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { SeriesID($0.seriesId) }
        }
    }

    // MARK: - Suggestions (pending-consent memberships, calendar-series-intelligence plan §2.1)

    /// The `'suggested'` (pending-consent) series memberships for a meeting — the meeting-detail
    /// suggestion banner's read.
    public func suggestedSeriesIds(forMeeting meetingId: MeetingID) async throws -> [SeriesID] {
        try await dbWriter.read { db in
            try SeriesMemberRecord
                .filter(Column("meetingId") == meetingId.rawValue)
                .filter(Column("linkSource") == "suggested")
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { SeriesID($0.seriesId) }
        }
    }

    /// The `'suggested'` (pending-consent) member meetings of a series.
    public func suggestedMeetingIds(inSeries seriesId: SeriesID) async throws -> [MeetingID] {
        try await dbWriter.read { db in
            try SeriesMemberRecord
                .filter(Column("seriesId") == seriesId.rawValue)
                .filter(Column("linkSource") == "suggested")
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { MeetingID($0.meetingId) }
        }
    }

    /// True if any membership row (any `linkSource`) already links `seriesId`/`meetingId` — the
    /// idempotency check `SeriesDetector` uses before writing (never overwrite an existing row).
    func hasAnyMember(seriesId: SeriesID, meetingId: MeetingID) async throws -> Bool {
        try await dbWriter.read { db in
            try SeriesMemberRecord.filter(
                Column("seriesId") == seriesId.rawValue && Column("meetingId") == meetingId.rawValue
            ).fetchCount(db) > 0
        }
    }

    /// Consent transition (the "yes" moment, calendar-series-intelligence plan §2.1): flips the
    /// membership `linkSource` `'suggested'` → `'auto'` and remembers the choice on the series
    /// (`autoAddMode` → `'always'`, so future occurrences add silently). One write transaction.
    public func confirmSuggestedMember(seriesId: SeriesID, meetingId: MeetingID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var member = try SeriesMemberRecord.fetchOne(
                db,
                key: ["seriesId": seriesId.rawValue, "meetingId": meetingId.rawValue]
            ), member.linkSource == "suggested" else { return }
            member.linkSource = "auto"
            try member.update(db)

            guard var series = try SeriesRecord.fetchOne(db, key: seriesId.rawValue) else { return }
            series.autoAddMode = "always"
            series.updatedAt = date
            try series.update(db)
        }
    }

    /// Consent transition (the "no" moment, plan §2.1): deletes the `'suggested'` row and
    /// remembers the choice on the series (`autoAddMode` → `'never'`, so it never nags again). A
    /// series left with zero member rows of any kind (it only ever existed as a suggestion) is
    /// tombstoned; a series with other real members is left alone. One write transaction.
    public func declineSuggestedMember(seriesId: SeriesID, meetingId: MeetingID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard let member = try SeriesMemberRecord.fetchOne(
                db,
                key: ["seriesId": seriesId.rawValue, "meetingId": meetingId.rawValue]
            ), member.linkSource == "suggested" else { return }
            try SeriesMemberRecord.deleteOne(
                db,
                key: ["seriesId": seriesId.rawValue, "meetingId": meetingId.rawValue]
            )

            guard var series = try SeriesRecord.fetchOne(db, key: seriesId.rawValue) else { return }
            series.autoAddMode = "never"
            series.updatedAt = date

            let remainingMembers = try SeriesMemberRecord
                .filter(Column("seriesId") == seriesId.rawValue)
                .fetchCount(db)
            if remainingMembers == 0 {
                series.isDeleted = true
                series.deletedAt = date
            }
            try series.update(db)
        }
    }

    /// Existence-check + insert in ONE write transaction (M2 fix): the check-then-act race between
    /// `hasAnyMember`/`addMember` as two separate transactions let two concurrent detections of the
    /// same `(series, meeting)` pair both observe "absent" and both write, producing a duplicate
    /// outcome (e.g. two fold-hook fires) even though `addMember`'s `save(db)` itself wouldn't
    /// throw (composite-PK upsert). This method makes the transaction outcome the single source of
    /// truth: returns `true` and writes the row only if no membership row for `(seriesId,
    /// meetingId)` existed yet; returns `false` and writes nothing otherwise.
    @discardableResult
    func insertMemberIfAbsent(
        seriesId: SeriesID,
        meetingId: MeetingID,
        occurrenceTime: String? = nil,
        linkSource: String? = nil,
        at date: Date = Date()
    ) async throws -> Bool {
        try await dbWriter.write { db in
            let alreadyExists = try SeriesMemberRecord.filter(
                Column("seriesId") == seriesId.rawValue && Column("meetingId") == meetingId.rawValue
            ).fetchCount(db) > 0
            guard !alreadyExists else { return false }

            try SeriesMemberRecord(
                seriesId: seriesId.rawValue,
                meetingId: meetingId.rawValue,
                occurrenceTime: occurrenceTime,
                linkSource: linkSource,
                createdAt: date
            ).insert(db)
            return true
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

    // MARK: - Mutations (create / rename / merge / delete — F9 series management)

    /// Creates a brand-new, meeting-less series (the series-list "+" affordance) — no
    /// `seriesKey`/owner/ledger, just a title. Returns the freshly generated `SeriesID`.
    @discardableResult
    public func createSeries(title: String, at date: Date = Date()) async throws -> SeriesID {
        let series = Series(
            id: SeriesID(UUID().uuidString),
            title: title,
            createdAt: date,
            updatedAt: date
        )
        try await upsert(series)
        return series.id
    }

    /// Renames a series. `upsert(_:)` only touches the `seriesLedger` row when the incoming
    /// `Series` carries ledger content (see its header) — since `find` hydrates the current
    /// ledger onto the value we mutate here, a rename round-trips the existing ledger untouched.
    public func rename(_ id: SeriesID, to title: String, at date: Date = Date()) async throws {
        guard var series = try await find(id) else { return }
        series.title = title
        series.updatedAt = date
        try await upsert(series)
    }

    /// Atomically absorbs `source` into `target`: every `source` member meeting not already in
    /// `target` is re-pointed to `target` (preserving its original `occurrenceTime`/`linkSource`/
    /// `createdAt`), `source`'s own member rows are removed, then `source` is tombstoned. The
    /// caller (view model) is responsible for rebuilding `target`'s ledger afterward — this is a
    /// pure membership operation.
    public func merge(source: SeriesID, into target: SeriesID, at date: Date = Date()) async throws {
        guard source != target else { return }

        try await dbWriter.write { db in
            let sourceMembers = try SeriesMemberRecord
                .filter(Column("seriesId") == source.rawValue)
                .fetchAll(db)

            let targetMeetingIds = try Set(
                SeriesMemberRecord
                    .filter(Column("seriesId") == target.rawValue)
                    .fetchAll(db)
                    .map(\.meetingId)
            )

            for member in sourceMembers where !targetMeetingIds.contains(member.meetingId) {
                try SeriesMemberRecord(
                    seriesId: target.rawValue,
                    meetingId: member.meetingId,
                    occurrenceTime: member.occurrenceTime,
                    linkSource: member.linkSource,
                    createdAt: member.createdAt
                ).insert(db)
            }

            try SeriesMemberRecord
                .filter(Column("seriesId") == source.rawValue)
                .deleteAll(db)

            guard var sourceRecord = try SeriesRecord.fetchOne(db, key: source.rawValue) else { return }
            sourceRecord.isDeleted = true
            sourceRecord.deletedAt = date
            try sourceRecord.update(db)
        }
    }

    /// Detaches every member meeting from `id` (hard-deletes the link rows, so the meeting's
    /// "Add to series" chip clears) and tombstones the series row itself, in one transaction.
    public func deleteSeries(_ id: SeriesID, at date: Date = Date()) async throws {
        try await dbWriter.write { db in
            try SeriesMemberRecord
                .filter(Column("seriesId") == id.rawValue)
                .deleteAll(db)

            guard var record = try SeriesRecord.fetchOne(db, key: id.rawValue) else { return }
            record.isDeleted = true
            record.deletedAt = date
            try record.update(db)
        }
    }

    /// The meetings belonging to a series ordered chronologically by meeting time (`createdAt`,
    /// then `id` as a stable tiebreak) — NOT link-creation order like `meetingIds(inSeries:)`.
    /// This is the ordering the ledger reducer's 1-based `mN` citation index is built against, so
    /// it must match what the detail view's timeline shows.
    ///
    /// L2 known limitation: this ordering is NOT immutable — linking a backdated/imported meeting
    /// (an earlier `createdAt` than an already-folded member) shifts every later member's index.
    /// `@mref(mN@…)` tokens already baked into the ledger are stored verbatim, so a shift like this
    /// can leave a stored, in-range `@mref` pointing at the wrong member until the series' ledger
    /// is manually rebuilt (`SeriesLedgerReducer.rebuildLedger`, which re-derives every index from
    /// this same ordering from scratch). See `SeriesLedgerReducer.foldMeeting`.
    public func orderedMeetingIds(inSeries seriesId: SeriesID) async throws -> [MeetingID] {
        try await dbWriter.read { db in
            // `'suggested'` memberships never consume an `@mref` citation index (calendar-series-
            // intelligence plan §2.1) — they only join in once confirmed.
            let rows = try Row.fetchAll(db, sql: """
            SELECT m.id AS id
            FROM seriesMember sm
            JOIN meeting m ON m.id = sm.meetingId
            WHERE sm.seriesId = ? AND m.isDeleted = 0
                AND (sm.linkSource IS NULL OR sm.linkSource <> 'suggested')
            ORDER BY m.createdAt ASC, m.id ASC
            """, arguments: [seriesId.rawValue])
            return rows.map { MeetingID($0["id"]) }
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
