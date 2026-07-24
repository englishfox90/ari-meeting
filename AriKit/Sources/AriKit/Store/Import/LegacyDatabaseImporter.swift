//
//  LegacyDatabaseImporter.swift — the one-time, read-only, idempotent legacy-library importer
//  (plan §5). The user's explicit "keep the data we have" requirement.
//
//  Orchestrates `ImportMapping`'s per-row translations against a read-only `LegacyDatabaseReader`,
//  writing through the SAME public repositories every other feature uses (`AppDatabase`'s
//  `meetings`/`persons`/… accessors) — never a second writer of the AriKit file, never a raw
//  record/table write outside a repository.
//
//  Table order is parent-before-child so every FK target a row references already exists by the
//  time that row is written (plan §5.2/§5.6): meetings → persons → speakers → speakerSegments →
//  transcripts → meetingNotes → summaries → profileFacts (two-pass, see below) →
//  profileFactSources → meeting series → series ledgers → series members → calendar events →
//  calendar sync settings.
//
//  Idempotent by construction: every repository's `upsert` is a GRDB `save(_:)` (insert-or-update
//  keyed on the stable legacy UUID primary key), so running the whole importer twice reaches the
//  same end state with no duplicate rows (plan §5.3) — this file adds no separate "already
//  imported?" bookkeeping because none is needed.
//
import Foundation
import GRDB

public struct LegacyDatabaseImporter: Sendable {
    let reader: LegacyDatabaseReader
    let store: AppDatabase

    public init(reader: LegacyDatabaseReader, store: AppDatabase) {
        self.reader = reader
        self.store = store
    }

    /// Convenience entry point matching plan §5.6's failure-mode table verbatim: a missing or
    /// unopenable legacy file becomes an `ImportReport` with zero tables and `sourceError` set —
    /// never a crash, never a silently-successful no-op. Prefer the throwing `run()` instance
    /// method (below) when the caller already has a `LegacyDatabaseReader` and wants real errors
    /// to propagate (e.g. tests).
    public static func run(sourceURL: URL, into store: AppDatabase) async -> ImportReport {
        let startedAt = Date()
        do {
            let reader = try LegacyDatabaseReader(sourceURL: sourceURL)
            return try await LegacyDatabaseImporter(reader: reader, store: store).run()
        } catch let error as LegacyReaderError {
            return ImportReport(
                tables: [],
                startedAt: startedAt,
                finishedAt: Date(),
                sourceError: .sourceNotFound(path: sourceURLPath(error))
            )
        } catch {
            return ImportReport(
                tables: [],
                startedAt: startedAt,
                finishedAt: Date(),
                warnings: ["Failed to open legacy database at \(sourceURL.path): \(error)"],
                sourceError: .openFailed(path: sourceURL.path, reason: "\(error)")
            )
        }
    }

    private static func sourceURLPath(_ error: LegacyReaderError) -> String {
        switch error {
        case let .sourceNotFound(path): path
        }
    }

    /// Runs the full table-by-table import. Throws only for a genuinely unexpected failure (the
    /// destination `AppDatabase` itself becoming unreachable, a SQL error reading the legacy
    /// schema) — a bad **row** is skipped and logged in that table's `skipReasons`, never aborts
    /// the whole run (plan §5.6).
    public func run() async throws -> ImportReport {
        let startedAt = Date()
        var warnings: [String] = []
        var tables: [ImportReport.TableResult] = []

        try await tables.append(importMeetings(warnings: &warnings))
        try await tables.append(importPersons(warnings: &warnings))
        try await tables.append(importSpeakers())
        try await tables.append(importSpeakerSegments())
        try await tables.append(importTranscripts(warnings: &warnings))
        try await tables.append(importMeetingNotes())
        try await tables.append(importSummaries())
        try await tables.append(importProfileFacts())
        try await tables.append(importProfileFactSources())
        try await tables.append(importMeetingSeries())
        try await tables.append(importSeriesLedgers())
        try await tables.append(importSeriesMembers())
        try await tables.append(importCalendarEvents(warnings: &warnings))
        try await tables.append(importCalendarSyncSettings())

        return ImportReport(tables: tables, startedAt: startedAt, finishedAt: Date(), warnings: warnings)
    }

    // MARK: - `meetings`

    private func importMeetings(warnings: inout [String]) async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meetings")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                let model = try ImportMapping.meeting(from: row)
                if let path = model.audioReference?.path,
                   !FileManager.default.fileExists(atPath: path) {
                    // §5.4: audio is referenced, never copied — a stale path (the legacy app-data
                    // dir moved/was deleted) is a known, accepted limitation, surfaced honestly
                    // rather than silently pointing at nothing.
                    warnings.append(
                        "meeting \(model.id.rawValue): audioReferencePath does not exist on disk: \(path)"
                    )
                }
                try await store.meetings.upsert(model)
                imported += 1
            } catch {
                skipReasons.append("meeting \(rowID(row)): \(error)")
            }
        }
        return tableResult("meetings", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `persons`

    private func importPersons(warnings: inout [String]) async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM persons")
        }
        var imported = 0
        var skipReasons: [String] = []
        var ownerCount = 0
        for row in rows {
            do {
                let model = try ImportMapping.person(from: row)
                if model.isOwner {
                    ownerCount += 1
                }
                // `upsert` (not `setOwner`) deliberately — a plain import must preserve whatever
                // `is_owner` values the legacy rows actually held, never re-derive them via the
                // single-true-row side effect `setOwner` applies (plan §0.1(4) governs live
                // writes, not historical data preservation).
                try await store.persons.upsert(model)
                imported += 1
            } catch {
                skipReasons.append("person \(rowID(row)): \(error)")
            }
        }
        if ownerCount > 1 {
            // §5.5: the legacy `is_owner` invariant ("exactly 0 or 1 rows should be 1") is
            // checked, not silently fixed — a violation is carried through faithfully and
            // flagged, matching the "carry the bug, don't mask it" policy for `audio_end_time`.
            warnings.append(
                "persons: \(ownerCount) rows have is_owner=1 (legacy single-owner invariant violated)"
            )
        }
        return tableResult("persons", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `speakers`

    private func importSpeakers() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM speakers")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                let model = try ImportMapping.speaker(from: row)
                try await store.speakers.upsert(model)
                imported += 1
            } catch {
                skipReasons.append("speaker \(rowID(row)): \(error)")
            }
        }
        return tableResult("speakers", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `speaker_segments`

    private func importSpeakerSegments() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM speaker_segments")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                let model = try ImportMapping.speakerSegment(from: row)
                try await store.speakerSegments.upsert(model)
                imported += 1
            } catch {
                skipReasons.append("speaker_segment \(rowID(row)): \(error)")
            }
        }
        return tableResult("speaker_segments", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `transcripts`

    private func importTranscripts(warnings: inout [String]) async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transcripts")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                let model = try ImportMapping.transcript(from: row)
                // §5.5: the known, pre-existing `audio_end_time` bug is copied through faithfully
                // (fixing source data is not this importer's job) — but flagged when it is
                // SELF-inconsistent with the row's own `duration`, the one signal actually
                // determinable from the DB alone (no audio file is decoded here).
                if let start = model.audioStartTime, let end = model.audioEndTime,
                   let duration = model.duration, duration > 0 {
                    let observed = end - start
                    if abs(observed - duration) > max(duration, 1.0) {
                        warnings.append(
                            "transcript \(model.id.rawValue): audio_end_time - audio_start_time "
                                + "(\(observed)s) is inconsistent with duration (\(duration)s)"
                        )
                    }
                }
                try await store.transcripts.upsert(model)
                imported += 1
            } catch {
                skipReasons.append("transcript \(rowID(row)): \(error)")
            }
        }
        return tableResult("transcripts", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `meeting_notes`

    private func importMeetingNotes() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meeting_notes")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                let model = try ImportMapping.meetingNote(from: row)
                try await store.meetingNotes.upsert(model)
                imported += 1
            } catch {
                skipReasons.append("meeting_note \(row["meeting_id"] as String? ?? "?"): \(error)")
            }
        }
        return tableResult("meeting_notes", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `summary_processes` → `summary` (best-effort; provider/model/templateId joined from `meetings`)

    private func importSummaries() async throws -> ImportReport.TableResult {
        // Read `summary_processes` DIRECTLY (not an inner JOIN onto `meetings`) so `sourceRowCount`
        // reflects EVERY source row — an orphaned process (a `meeting_id` with no matching meeting)
        // must be counted + reported as a skip, never silently excluded from the reconciliation
        // baseline (No-Fake-State, plan §5.5). The meeting-side columns (`summary_provider`/
        // `summary_model`/`template_id`) are looked up from a pre-built map instead.
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM summary_processes")
        }
        let meetingRows = try reader.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, summary_provider, summary_model, template_id FROM meetings"
            )
        }
        var meetingInfo: [String: Row] = [:]
        for m in meetingRows {
            if let id = m["id"] as String? {
                meetingInfo[id] = m
            }
        }

        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            let meetingId = row["meeting_id"] as String? ?? "?"
            guard let resultJSON = row["result"] as String? else {
                // A summary process with no `result` yet (still pending/never completed) has
                // nothing to import — a legitimate skip, not a malformed row.
                skipReasons.append("summary_processes \(meetingId): no result yet")
                continue
            }
            guard let meetingRow = meetingInfo[meetingId] else {
                // Orphan: no matching meeting row, so the summary→meeting FK can't be satisfied.
                // Counted + reported (would have been silently invisible under the old inner JOIN).
                skipReasons.append("summary_processes \(meetingId): no matching meeting row (orphan)")
                continue
            }
            do {
                let bodyMarkdown = try ImportMapping.summaryBodyMarkdown(fromResultJSON: resultJSON)
                let createdAt = try ImportMapping.date(row, "created_at")
                let updatedAt = try ImportMapping.date(row, "updated_at")
                let summary = Summary(
                    id: SummaryID(meetingId),
                    meetingId: MeetingID(meetingId),
                    bodyMarkdown: bodyMarkdown,
                    provider: meetingRow["summary_provider"],
                    model: meetingRow["summary_model"],
                    templateId: meetingRow["template_id"],
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
                try await store.summaries.upsert(summary)
                imported += 1
            } catch {
                // §5.5: the malformed-result case is skipped and REPORTED, never silently
                // dropped.
                skipReasons.append("summary_processes \(meetingId): \(error)")
            }
        }
        return tableResult("summary_processes", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `profile_facts` (two-pass: self-FK `supersededBy`)

    /// Pass 1 inserts every fact with `supersededBy = nil` so all rows exist. Pass 2 re-upserts
    /// any fact whose legacy `superseded_by` is non-null with the real pointer now set — by then
    /// every target row exists (the FK is self-referential, so any target is necessarily another
    /// row in this same table), satisfying SQLite's `PRAGMA foreign_keys = ON` check without
    /// needing to topologically sort the legacy rows first.
    private func importProfileFacts() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM profile_facts")
        }
        var imported = 0
        var skipReasons: [String] = []
        var facts: [(row: Row, fact: ProfileFact, supersededBy: String?)] = []

        for row in rows {
            do {
                let fact = try ImportMapping.profileFact(from: row)
                facts.append((row, fact, row["superseded_by"] as String?))
            } catch {
                skipReasons.append("profile_fact \(rowID(row)): \(error)")
            }
        }

        // Pass 1 — every fact, supersededBy always nil at this point (`ImportMapping.profileFact`
        // never sets it).
        for (_, fact, _) in facts {
            try await store.profileFacts.upsert(fact)
            imported += 1
        }

        // Pass 2 — re-upsert with the real pointer, now that every target row exists.
        for (row, fact, supersededBy) in facts {
            guard let supersededBy else { continue }
            var updated = fact
            updated.supersededBy = ProfileFactID(supersededBy)
            do {
                try await store.profileFacts.upsert(updated)
            } catch {
                // The pointer's target doesn't actually exist in this legacy file (a dangling
                // `superseded_by` — data corruption upstream, not something to paper over): the
                // fact itself is still imported from pass 1, just without the supersession edge.
                skipReasons.append(
                    "profile_fact \(rowID(row)): could not set supersededBy=\(supersededBy): \(error)"
                )
            }
        }

        return tableResult("profile_facts", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `profile_fact_sources`

    private func importProfileFactSources() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM profile_fact_sources")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                let model = try ImportMapping.profileFactSource(from: row)
                try await store.profileFacts.recordSource(model)
                imported += 1
            } catch {
                skipReasons.append("profile_fact_source \(rowID(row)): \(error)")
            }
        }
        return tableResult("profile_fact_sources", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `meeting_series`

    private func importMeetingSeries() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meeting_series")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                let model = try ImportMapping.series(from: row)
                try await store.series.upsert(model)
                imported += 1
            } catch {
                skipReasons.append("meeting_series \(rowID(row)): \(error)")
            }
        }
        return tableResult("meeting_series", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `series_ledger` (fills in the fields `Series` doesn't carry — plan §4.7)

    private func importSeriesLedgers() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM series_ledger")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            let seriesId = row["series_id"] as String? ?? "?"
            do {
                let updatedFromMeetingId = (row["updated_from_meeting_id"] as String?).map { MeetingID($0) }
                let updatedAt = try ImportMapping.date(row, "updated_at")
                try await store.series.updateLedger(
                    seriesId: SeriesID(seriesId),
                    ledgerMarkdown: row["ledger_markdown"],
                    structuredJson: row["structured_json"],
                    updatedFromMeetingId: updatedFromMeetingId,
                    ledgerVersion: row["version"] as Int,
                    at: updatedAt
                )
                imported += 1
            } catch {
                skipReasons.append("series_ledger \(seriesId): \(error)")
            }
        }
        return tableResult("series_ledger", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `meeting_series_members`

    private func importSeriesMembers() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meeting_series_members")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            let seriesId = row["series_id"] as String? ?? "?"
            let meetingId = row["meeting_id"] as String? ?? "?"
            do {
                let createdAt = try ImportMapping.date(row, "created_at")
                try await store.series.addMember(
                    seriesId: SeriesID(seriesId),
                    meetingId: MeetingID(meetingId),
                    occurrenceTime: row["occurrence_time"],
                    linkSource: row["link_source"],
                    at: createdAt
                )
                imported += 1
            } catch {
                skipReasons.append("meeting_series_member \(seriesId)/\(meetingId): \(error)")
            }
        }
        return tableResult("meeting_series_members", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    // MARK: - `calendar_events`

    private func importCalendarEvents(warnings: inout [String]) async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM calendar_events")
        }

        // Dedupe pre-pass (calendar-series-intelligence plan §4/§7 step 1, feature 4): the legacy
        // DB can in principle carry multiple events linked to the same meeting ("shouldn't
        // happen", `calendar.rs:286-287`). Group by meeting_id and keep exactly one winner —
        // latest `start_time`, tie-broken by `id` — BEFORE any row is upserted, so the outcome is
        // deterministic (not dependent on `SELECT` row order) and every dropped link is reported.
        // Without this pre-pass, `CalendarEventRepository.upsert`'s new clear-competitors write
        // (§2.1) would still land on exactly one winner, but silently and order-dependently.
        var winners: [String: (rowID: String, startTime: Date?)] = [:]
        for row in rows {
            guard let meetingId = row["meeting_id"] as String? else { continue }
            let id: String = row["id"]
            let startTime = try? ImportMapping.date(row, "start_time")
            if let current = winners[meetingId] {
                if calendarEventDedupeWinner(id: id, startTime: startTime, over: current) {
                    winners[meetingId] = (id, startTime)
                }
            } else {
                winners[meetingId] = (id, startTime)
            }
        }

        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                var (model, attendeesMalformed) = try ImportMapping.calendarEvent(from: row)
                if attendeesMalformed {
                    warnings.append(
                        "calendar_event \(model.id.rawValue): attendees JSON malformed, "
                            + "imported with an empty attendee list"
                    )
                }
                if let meetingId = model.meetingId, winners[meetingId.rawValue]?.rowID != model.id.rawValue {
                    warnings.append(
                        "calendar_event \(model.id.rawValue): dropped duplicate link to meeting "
                            + "\(meetingId.rawValue) (a more recently-starting linked event keeps it)"
                    )
                    model.meetingId = nil
                    model.linkSource = nil
                }
                try await store.calendarEvents.upsert(model)
                imported += 1
            } catch {
                skipReasons.append("calendar_event \(rowID(row)): \(error)")
            }
        }
        return tableResult("calendar_events", rows: rows, imported: imported, skipReasons: skipReasons)
    }

    /// True when the candidate (`id`/`startTime`) should replace `current` as the surviving link
    /// for a `meeting_id` group: later `start_time` wins; a missing `start_time` always loses to a
    /// present one; equal (or equally-missing) `start_time` ties are broken by the greater `id`,
    /// for a fully deterministic outcome independent of `SELECT` row order.
    private func calendarEventDedupeWinner(
        id: String,
        startTime: Date?,
        over current: (rowID: String, startTime: Date?)
    ) -> Bool {
        switch (startTime, current.startTime) {
        case let (.some(lhs), .some(rhs)):
            lhs != rhs ? lhs > rhs : id > current.rowID
        case (.some, .none):
            true
        case (.none, .some):
            false
        case (.none, .none):
            id > current.rowID
        }
    }

    // MARK: - `calendar_sync_settings`

    private func importCalendarSyncSettings() async throws -> ImportReport.TableResult {
        let rows = try reader.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM calendar_sync_settings")
        }
        var imported = 0
        var skipReasons: [String] = []
        for row in rows {
            do {
                try await store.calendarEvents.setSyncSetting(
                    calendarId: row["calendar_id"],
                    calendarTitle: row["calendar_title"],
                    color: row["color"],
                    selected: (row["selected"] as Int) != 0
                )
                imported += 1
            } catch {
                skipReasons.append("calendar_sync_setting \(row["calendar_id"] as String? ?? "?"): \(error)")
            }
        }
        return tableResult(
            "calendar_sync_settings", rows: rows, imported: imported, skipReasons: skipReasons
        )
    }

    // MARK: - Shared helpers

    private func rowID(_ row: Row) -> String {
        (row["id"] as String?) ?? "?"
    }

    private func tableResult(
        _ table: String,
        rows: [Row],
        imported: Int,
        skipReasons: [String]
    ) -> ImportReport.TableResult {
        ImportReport.TableResult(
            table: table,
            sourceRowCount: rows.count,
            importedCount: imported,
            skippedCount: skipReasons.count,
            skipReasons: skipReasons
        )
    }
}
