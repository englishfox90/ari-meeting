//
//  ImportMapping.swift — table-by-table legacy row → `AriKit.Models.*` mapping (plan §5.2).
//
//  Every function is a pure, throwing translation: a legacy `GRDB.Row` in, a domain value out.
//  A malformed row throws `ImportMappingError`, letting `LegacyDatabaseImporter` skip just that
//  row and log it — one bad row never aborts a whole table (plan §5.6).
//
//  Dates: legacy TEXT timestamp columns are RFC3339 (sqlx/chrono `DateTime<Utc>` encoding),
//  parsed with the same internal `RFC3339` helper `Models/Support/ModelsCoding.swift` uses for
//  the real engine JSON fixtures — one date policy, not a second one invented here.
//
//  Two columns are deliberately NOT read into any model, matching already-documented Store
//  deltas: `transcripts.summary`/`.action_items`/`.key_points`/`.speaker` (pre-chunking-era cache
//  + the dead mic/system label — `Records/TranscriptRecord.swift`, plan §4.2/§4.10) and
//  `meetings.template_id` / `meeting_series.template_id` (no `templateId` field on the domain
//  types yet — `Records/MeetingRecord.swift` / `Records/SeriesRecord.swift`).
//
import Foundation
import GRDB

/// A row failed to map into a domain value (plan §5.6 — skip the row, not the table).
enum ImportMappingError: Error, Sendable, CustomStringConvertible {
    case invalidDate(column: String, raw: String)
    case malformedSummaryResult(String)

    var description: String {
        switch self {
        case let .invalidDate(column, raw):
            "invalid date in column '\(column)': \"\(raw)\""
        case let .malformedSummaryResult(reason):
            "malformed summary_processes.result: \(reason)"
        }
    }
}

enum ImportMapping {

    // MARK: - Date parsing

    /// Uses the OPTIONAL subscript (`as String?`) deliberately: GRDB's non-optional `row[column]`
    /// is a `try!`-wrapped decode that *fatalErrors* on a missing column or a NULL value, which
    /// would abort the ENTIRE import (violating plan §5.6's "one bad row never aborts the whole
    /// import"). Reading optionally and throwing instead degrades a missing/NULL/malformed date to
    /// a per-row skip. (The other non-optional `row[...]` reads in this file rely on the legacy
    /// schema's NOT-NULL guarantees — additive migrations — which dates share, but dates are the
    /// one place a malformed *value* rather than a wrong *type* is plausible, so they're hardened.)
    static func date(_ row: Row, _ column: String) throws -> Date {
        guard let raw = row[column] as String? else {
            throw ImportMappingError.invalidDate(column: column, raw: "<missing or null>")
        }
        guard let parsed = RFC3339.date(from: raw) else {
            throw ImportMappingError.invalidDate(column: column, raw: raw)
        }
        return parsed
    }

    static func optionalDate(_ row: Row, _ column: String) throws -> Date? {
        guard let raw = row[column] as String? else { return nil }
        guard let parsed = RFC3339.date(from: raw) else {
            throw ImportMappingError.invalidDate(column: column, raw: raw)
        }
        return parsed
    }

    // MARK: - `meetings` → `Meeting`

    static func meeting(from row: Row) throws -> Meeting {
        try Meeting(
            id: MeetingID(row["id"] as String),
            title: row["title"],
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at"),
            audioReference: (row["folder_path"] as String?).map(LocalAudioReference.init(path:)),
            transcriptionProvider: row["transcription_provider"],
            transcriptionModel: row["transcription_model"],
            summaryProvider: row["summary_provider"],
            summaryModel: row["summary_model"]
        )
    }

    // MARK: - `persons` → `Person`

    static func person(from row: Row) throws -> Person {
        try Person(
            id: PersonID(row["id"] as String),
            email: row["email"],
            displayName: row["display_name"],
            role: row["role"],
            organization: row["organization"],
            domain: row["domain"],
            notes: row["notes"],
            isOwner: (row["is_owner"] as Int) != 0,
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at")
        )
    }

    // MARK: - `speakers` → `Speaker`

    static func speaker(from row: Row) throws -> Speaker {
        let enrollmentRaw: String = row["enrollment_state"]
        return try Speaker(
            id: SpeakerID(row["id"] as String),
            personId: (row["person_id"] as String?).map { PersonID($0) },
            label: row["label"],
            centroid: row["centroid"],
            embeddingModel: row["embedding_model"],
            dim: row["dim"],
            samples: row["samples"],
            enrollmentState: EnrollmentState(rawValue: enrollmentRaw) ?? .unknownCase(enrollmentRaw),
            totalSpeechSecs: row["total_speech_secs"],
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at")
        )
    }

    // MARK: - `speaker_segments` → `SpeakerSegment`

    /// Legacy `source` values are `'microphone'`/`'system'` — neither matches `SegmentSource`'s
    /// only known case (`.import`), so both round-trip losslessly as `.unknown("microphone")` /
    /// `.unknown("system")` (the forward-tolerant-enum pattern working as designed, not a bug).
    static func speakerSegment(from row: Row) throws -> SpeakerSegment {
        let sourceRaw: String = row["source"]
        return try SpeakerSegment(
            id: SpeakerSegmentID(row["id"] as String),
            meetingId: MeetingID(row["meeting_id"] as String),
            speakerId: (row["speaker_id"] as String?).map { SpeakerID($0) },
            clusterKey: row["cluster_key"],
            startTime: row["start_time"],
            endTime: row["end_time"],
            source: SegmentSource(rawValue: sourceRaw) ?? .unknownCase(sourceRaw),
            embedding: row["embedding"],
            createdAt: date(row, "created_at")
        )
    }

    // MARK: - `transcripts` → `Transcript`

    static func transcript(from row: Row) throws -> Transcript {
        Transcript(
            id: TranscriptID(row["id"] as String),
            meetingId: MeetingID(row["meeting_id"] as String),
            transcript: row["transcript"],
            timestamp: row["timestamp"],
            audioStartTime: row["audio_start_time"],
            audioEndTime: row["audio_end_time"],
            duration: row["duration"],
            speakerId: (row["speaker_id"] as String?).map { SpeakerID($0) }
        )
    }

    // MARK: - `meeting_notes` → `MeetingNote`

    static func meetingNote(from row: Row) throws -> MeetingNote {
        try MeetingNote(
            meetingId: MeetingID(row["meeting_id"] as String),
            notesMarkdown: row["notes_markdown"],
            notesJson: row["notes_json"],
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at")
        )
    }

    // MARK: - `profile_facts` → `ProfileFact`

    /// `supersededBy` is always `nil` here — the importer's self-FK two-pass (see
    /// `LegacyDatabaseImporter.importProfileFacts()`) sets the real pointer in a second pass,
    /// once every fact row exists. `sourceMeetingTitle`/`sourceCount` are read-time-computed
    /// (plan §4.6, No-Fake-State) and ignored by `ProfileFactRecord` on write regardless of what
    /// is passed here — the placeholders below are inert, never persisted.
    static func profileFact(from row: Row) throws -> ProfileFact {
        let factKindRaw: String = row["fact_kind"]
        let originRaw: String = row["source_kind"]
        let statusRaw: String = row["status"]
        return try ProfileFact(
            id: ProfileFactID(row["id"] as String),
            personId: PersonID(row["person_id"] as String),
            factText: row["fact_text"],
            factKind: FactKind(rawValue: factKindRaw) ?? .unknownCase(factKindRaw),
            sourceMeetingId: (row["source_meeting_id"] as String?).map { MeetingID($0) },
            sourceMeetingTitle: nil,
            sourceSegmentRef: row["source_segment_ref"],
            origin: FactOrigin(rawValue: originRaw) ?? .unknownCase(originRaw),
            confidence: row["confidence"],
            sourceCount: 0,
            status: FactStatus(rawValue: statusRaw) ?? .unknownCase(statusRaw),
            supersededBy: nil,
            createdAt: date(row, "created_at")
        )
    }

    // MARK: - `profile_fact_sources` → `ProfileFactSource`

    /// `meetingTitle` is read-time-computed (plan §4.6) and ignored by `ProfileFactSourceRecord`
    /// on write — the `nil` placeholder below is inert.
    static func profileFactSource(from row: Row) throws -> ProfileFactSource {
        let originRaw: String = row["source_kind"]
        let relationRaw: String = row["relation"]
        return try ProfileFactSource(
            id: ProfileFactSourceID(row["id"] as String),
            factId: ProfileFactID(row["fact_id"] as String),
            meetingId: (row["meeting_id"] as String?).map { MeetingID($0) },
            meetingTitle: nil,
            segmentRef: row["segment_ref"],
            origin: FactOrigin(rawValue: originRaw) ?? .unknownCase(originRaw),
            relation: FactSourceRelation(rawValue: relationRaw) ?? .unknownCase(relationRaw),
            confidence: row["confidence"],
            observedAt: date(row, "observed_at")
        )
    }

    // MARK: - `meeting_series` → `Series`

    /// `ledgerMarkdown`/`ledgerVersion` are always `nil` here — a separate `series_ledger` row
    /// (imported by `LegacyDatabaseImporter.importSeriesLedgers()`, after every `series` row
    /// exists) fills them in via `SeriesRepository.updateLedger(...)`, mirroring how the schema
    /// itself keeps the two tables split (plan §4.7).
    static func series(from row: Row) throws -> Series {
        try Series(
            id: SeriesID(row["id"] as String),
            title: row["title"],
            seriesKey: row["series_key"],
            detectedType: row["detected_type"],
            cadence: row["cadence"],
            ownerPersonId: (row["owner_person_id"] as String?).map { PersonID($0) },
            ledgerMarkdown: nil,
            ledgerVersion: nil,
            createdAt: date(row, "created_at"),
            updatedAt: date(row, "updated_at")
        )
    }

    // MARK: - `calendar_events` → `CalendarEvent`

    /// Throws only on a genuinely malformed row (an unparseable required date). A malformed
    /// `attendees` JSON blob is tolerated — falls back to `[]`, reported via `attendeesMalformed`
    /// so the caller can log a warning without discarding the rest of an otherwise-valid event
    /// (the row is real data; only its attendee sub-list is unreadable).
    static func calendarEvent(from row: Row) throws -> (event: CalendarEvent, attendeesMalformed: Bool) {
        let linkSourceRaw = row["link_source"] as String?
        var attendeesMalformed = false
        let attendees: [Attendee]
        if let attendeesJSON = row["attendees"] as String?, !attendeesJSON.isEmpty {
            if let decoded = try? Models.jsonDecoder.decode(
                [Attendee].self,
                from: Data(attendeesJSON.utf8)
            ) {
                attendees = decoded
            } else {
                attendees = []
                attendeesMalformed = true
            }
        } else {
            attendees = []
        }
        let event = try CalendarEvent(
            id: CalendarEventID(row["id"] as String),
            calendarId: row["calendar_id"],
            calendarTitle: row["calendar_title"],
            title: row["title"],
            startTime: date(row, "start_time"),
            endTime: date(row, "end_time"),
            isAllDay: (row["is_all_day"] as Int) != 0,
            location: row["location"],
            notes: row["notes"],
            organizer: row["organizer"],
            attendees: attendees,
            meetingId: (row["meeting_id"] as String?).map { MeetingID($0) },
            linkSource: linkSourceRaw.map { raw in CalendarLinkSource(rawValue: raw) ?? .unknownCase(raw) },
            seriesKey: row["series_key"],
            hasRecurrence: (row["has_recurrence"] as Int?).map { $0 != 0 },
            occurrenceDate: optionalDate(row, "occurrence_date"),
            isDetached: (row["is_detached"] as Int?).map { $0 != 0 }
        )
        return (event, attendeesMalformed)
    }

    // MARK: - `summary_processes.result` → `Summary.bodyMarkdown` (best-effort; plan §5.2/§5.5)

    /// Parses the legacy JSON blob into Markdown, best-effort. Recognizes the two shapes the
    /// frozen engine actually writes (`ari-engine/src/summary/commands.rs::SummaryResponse`'s
    /// `data` field, containing either a `markdown` string or the pre-BlockNote legacy
    /// section-dictionary format the frontend's `Summary`/`SummaryDataResponse` types describe:
    /// non-meta keys map to `{title, blocks:[{content}]}`). Throws `.malformedSummaryResult` for
    /// anything else — invalid JSON, or JSON that matches neither shape — so the caller skips and
    /// logs that one row rather than fabricating a body from data that isn't really there
    /// (No-Fake-State).
    static func summaryBodyMarkdown(fromResultJSON resultJSON: String) throws -> String {
        guard let data = resultJSON.data(using: .utf8),
              let topLevel = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ImportMappingError.malformedSummaryResult("not a JSON object")
        }
        // The app's `summary_processes.result` is the summary engine's cache shape:
        // `{"markdown": "<rendered>", "english_cache": {"markdown": "<rendered>", …}}` — there is
        // no `data` block. Prefer the rendered markdown directly (top-level, then the language
        // cache); the `{"data": {…}}` block shape below is an older/alternate result format kept
        // only as a fallback so both real histories import.
        if let markdown = topLevel["markdown"] as? String, !markdown.isEmpty {
            return markdown
        }
        if let cache = topLevel["english_cache"] as? [String: Any],
           let markdown = cache["markdown"] as? String, !markdown.isEmpty {
            return markdown
        }
        guard let payload = topLevel["data"] as? [String: Any] else {
            throw ImportMappingError.malformedSummaryResult("no \"data\", \"markdown\", or \"english_cache\" field")
        }
        if let markdown = payload["markdown"] as? String, !markdown.isEmpty {
            return markdown
        }

        let metaKeys: Set = ["markdown", "summary_json", "MeetingName", "_section_order"]
        var lines: [String] = []
        if let meetingName = payload["MeetingName"] as? String {
            lines.append("# \(meetingName)")
        }
        let order = (payload["_section_order"] as? [String])
            ?? payload.keys.filter { !metaKeys.contains($0) }.sorted()
        for key in order {
            guard let section = payload[key] as? [String: Any] else { continue }
            let title = (section["title"] as? String) ?? key
            lines.append("## \(title)")
            if let blocks = section["blocks"] as? [[String: Any]] {
                for block in blocks {
                    if let content = block["content"] as? String, !content.isEmpty {
                        lines.append(content)
                    }
                }
            }
        }
        guard !lines.isEmpty else {
            throw ImportMappingError.malformedSummaryResult("unrecognized \"data\" shape")
        }
        return lines.joined(separator: "\n\n")
    }
}
