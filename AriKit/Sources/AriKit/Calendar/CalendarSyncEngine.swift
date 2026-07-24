//
//  CalendarSyncEngine.swift — the S7 sync core: fetch → upsert (link-preserving) → prune-in-range
//  → auto-match, one full pass (plan §2.2, §4). Pure orchestration over `CalendarSourcing` +
//  repositories — zero EventKit import, fully headless (Lane-1 testable with a fake source).
//
//  Parity with `sync_range_core` (`sync.rs:28-81`) — the attendee→person reconcile hook landed in
//  the people-view-parity slice; series auto-detection (`sync.rs:72, 85-105`) lands in
//  `calendar-series-intelligence.md` §2.2/§7 step 4 as `runSeriesDetection`, inserted between
//  `runAutoMatch` and `runAttendeeImport` (Rust order).
//
import Foundation
import os

public struct CalendarSyncReport: Sendable, Equatable {
    /// Events returned by the source this pass (parity: `sync.rs:80` return value).
    public var fetched: Int
    public var pruned: Int
    public var autoLinked: Int
    /// Participant links established this pass by the calendar attendee→person import (plan §2.6,
    /// `people-view-parity.md`) — honest telemetry, never fabricated (No-Fake-State).
    public var importedParticipants: Int
    /// NEW series memberships written this pass by `SeriesDetector` — `'suggested'` + `'auto'`
    /// combined (calendar-series-intelligence plan §2.2). Honest telemetry: a re-run reports 0.
    /// Defaulted so existing call sites stay source-compatible.
    public var seriesMemberships: Int

    public init(
        fetched: Int, pruned: Int, autoLinked: Int, importedParticipants: Int = 0,
        seriesMemberships: Int = 0
    ) {
        self.fetched = fetched
        self.pruned = pruned
        self.autoLinked = autoLinked
        self.importedParticipants = importedParticipants
        self.seriesMemberships = seriesMemberships
    }
}

private let seriesDetectionLogger = Logger(subsystem: "com.arivo.ari.AriKit", category: "calendar.series")

public struct CalendarSyncEngine: Sendable {
    /// Auto-match slack window (parity: `sync.rs:16` `AUTO_MATCH_SLACK_MINUTES`).
    private static let autoMatchSlack: TimeInterval = 15 * 60
    /// Background window (parity: `sync.rs:20-22`).
    private static let backgroundPastDays: TimeInterval = 30 * 24 * 60 * 60
    private static let backgroundFutureDays: TimeInterval = 90 * 24 * 60 * 60

    private let source: any CalendarSourcing
    private let database: AppDatabase
    /// Fired fire-and-forget when `SeriesDetector` writes a consented `'auto'` membership (the
    /// `'always'` path only — a merely `'suggested'` one has not been consented to yet, plan
    /// §2.2). `nil` by default; the app target supplies the ledger-fold hook.
    private let onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)?
    /// Test-only (module-internal) override of `SeriesDetector.detect`, so
    /// `CalendarSyncEngineTests` can deterministically fault-inject a per-event detector failure
    /// (e.g. a `.failed` outcome the fake throws for one specific event id) without corrupting the
    /// database — a genuinely dangling foreign-key reference can never arise through any real
    /// write path in this engine (the schema's own foreign keys guarantee consistency at every
    /// step), so a literal "poisoned row" isn't reachable except via direct SQL surgery that would
    /// also break the surrounding sync steps (`syncUpsert`/`pruneStaleEvents`) before detection
    /// ever ran. `nil` in production, where the real `SeriesDetector` is always used. Not part of
    /// the public initializer — mirrors `AddToSeriesViewModel.pendingFoldTask`'s
    /// test-hook-not-public-contract precedent.
    private let detectOverride: (@Sendable (CalendarEvent, Date) async throws -> SeriesDetector.Outcome)?

    public init(
        source: any CalendarSourcing,
        database: AppDatabase,
        onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)? = nil
    ) {
        self.init(
            source: source, database: database,
            onAutoSeriesMembership: onAutoSeriesMembership, detectOverride: nil
        )
    }

    init(
        source: any CalendarSourcing,
        database: AppDatabase,
        onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)? = nil,
        detectOverride: (@Sendable (CalendarEvent, Date) async throws -> SeriesDetector.Outcome)?
    ) {
        self.source = source
        self.database = database
        self.onAutoSeriesMembership = onAutoSeriesMembership
        self.detectOverride = detectOverride
    }

    /// Fetch → upsert (link-preserving) → prune-in-range → auto-match. One full pass.
    ///
    /// Only calendars currently `selected` are fetched (parity: `calendar.rs:133-138` +
    /// `eventkit.rs:184-186` — an empty selection is a source-level short-circuit to `[]`, which
    /// naturally falls out of passing an empty id list through to `source.fetchEvents`; nothing
    /// syncs until the user opts calendars in, plan §4 item 5).
    public func syncRange(from start: Date, to end: Date, now: Date = Date()) async throws -> CalendarSyncReport {
        let selectedIds = try await database.calendarEvents.selectedCalendarIds()
        let nativeEvents = try await source.fetchEvents(calendarIds: selectedIds, from: start, to: end)
        let events = nativeEvents.map(Self.asCalendarEvent)

        try await database.calendarEvents.syncUpsert(events, at: now)

        let range = start ... end
        let fetchedIds = Set(events.map(\.id))
        let pruned = try await database.calendarEvents.pruneStaleEvents(
            startingIn: range,
            keeping: fetchedIds,
            at: now
        )

        let autoLinked = try await runAutoMatch(in: range)
        let seriesMemberships = await runSeriesDetection(in: range, now: now)
        let importedParticipants = try await runAttendeeImport(in: range, now: now)

        return CalendarSyncReport(
            fetched: events.count,
            pruned: pruned,
            autoLinked: autoLinked,
            importedParticipants: importedParticipants,
            seriesMemberships: seriesMemberships
        )
    }

    /// Convenience matching the Rust background window: now-30d … now+90d (`sync.rs:21-22`).
    public func syncDefaultWindow(now: Date = Date()) async throws -> CalendarSyncReport {
        let start = now.addingTimeInterval(-Self.backgroundPastDays)
        let end = now.addingTimeInterval(Self.backgroundFutureDays)
        return try await syncRange(from: start, to: end, now: now)
    }

    /// Refresh `calendarSyncSetting` identities from the source, preserving `selected` (parity:
    /// `calendar_list_calendars_impl`, `commands.rs:58-83`). Returns rows for the VM.
    public func refreshCalendarList() async throws
        -> [(calendarId: String, calendarTitle: String?, color: String?, selected: Bool)] {
        let calendars = try await source.listCalendars()
        var rows: [(calendarId: String, calendarTitle: String?, color: String?, selected: Bool)] = []
        rows.reserveCapacity(calendars.count)
        for calendar in calendars {
            let row = try await database.calendarEvents.upsertCalendarIdentity(
                calendarId: calendar.id,
                title: calendar.title,
                color: calendar.color
            )
            rows.append(row)
        }
        return rows
    }

    // MARK: - Auto-match (parity: `sync.rs:136-174` + `calendar.rs:254-271, 324-341, 399-423`)

    /// For each event in `range` whose link is not manual, find the meeting whose `createdAt`
    /// falls in `[event.start − 15min, event.end + 15min]`, closest to `event.start`, and link
    /// it (re-guarded against manual at the write site). Already-auto-linked events are
    /// re-evaluated every pass and may be re-pointed at a closer meeting; if no meeting matches,
    /// an existing auto link is left as-is (no candidate ⇒ no write). Manual links are never
    /// touched. Returns the number of events for which an auto link was written this pass.
    private func runAutoMatch(in range: ClosedRange<Date>) async throws -> Int {
        let candidates = try await database.calendarEvents.autoLinkableEvents(startingIn: range)
        var autoLinkedCount = 0
        for event in candidates {
            let windowStart = event.startTime.addingTimeInterval(-Self.autoMatchSlack)
            let windowEnd = event.endTime.addingTimeInterval(Self.autoMatchSlack)
            guard let meetingId = try await database.meetings.closestMeetingID(
                createdBetween: windowStart,
                and: windowEnd,
                to: event.startTime
            ) else {
                continue
            }
            let linked = try await database.calendarEvents.setAutoLink(eventId: event.id, meetingId: meetingId)
            if linked {
                autoLinkedCount += 1
            }
        }
        return autoLinkedCount
    }

    // MARK: - Series auto-detection (calendar-series-intelligence plan §2.2, feature 1)

    /// For each non-tombstoned event in `range` (read from the persisted rows — same rationale as
    /// `runAttendeeImport`), runs `SeriesDetector.detect`. Best-effort: a per-event failure is
    /// logged and never breaks the sync pass or skips detection for subsequent events (parity
    /// `sync.rs:83-105`). On `.autoAdded`, fires `onAutoSeriesMembership` fire-and-forget — never
    /// blocking this sync pass on a ledger fold. Returns the count of NEW memberships written
    /// (`'suggested'` + `'auto'`) — honest telemetry, a re-run reports 0.
    private func runSeriesDetection(in range: ClosedRange<Date>, now: Date) async -> Int {
        let events: [CalendarEvent]
        do {
            events = try await database.calendarEvents.events(startingIn: range)
        } catch {
            seriesDetectionLogger.error("series detection: failed to read events in range: \(error)")
            return 0
        }

        let detector = SeriesDetector(database: database)
        let detect = detectOverride ?? { try await detector.detect(for: $0, at: $1) }
        var newMemberships = 0
        for event in events {
            do {
                switch try await detect(event, now) {
                case .skipped:
                    break
                case .suggested:
                    newMemberships += 1
                case .autoAdded:
                    newMemberships += 1
                    if let hook = onAutoSeriesMembership, let meetingId = event.meetingId {
                        Task.detached(priority: .utility) { await hook(meetingId) }
                    }
                }
            } catch {
                seriesDetectionLogger.error(
                    "series detection failed for event \(event.id.rawValue, privacy: .private): \(error)"
                )
                continue
            }
        }
        return newMemberships
    }

    // MARK: - Attendee→person import (parity: `persons/import.rs` + `people-view-parity.md` §2.6)

    /// For each non-tombstoned event in `range` that is linked to a meeting (read from the
    /// persisted row — NOT the in-memory `NativeEvent`, which never carries a link), turn its
    /// attendee list into `Person` stubs and link them as `meetingParticipant` rows with
    /// `linkSource = "calendar"`. Runs AFTER `runAutoMatch` so a newly auto-linked event's
    /// attendees import in the same pass. Fully idempotent (email-keyed dedup in
    /// `upsertStubFromAttendee`, `INSERT OR IGNORE` in `addParticipant`, and an additional
    /// within-meeting displayName dedup for email-less attendees) — safe to re-run every sync.
    /// Returns the number of NEW participant links established this pass (honest telemetry — a
    /// re-run over already-imported attendees reports 0, not the attempted count).
    private func runAttendeeImport(in range: ClosedRange<Date>, now: Date) async throws -> Int {
        let events = try await database.calendarEvents.events(startingIn: range)
        var importedCount = 0
        for event in events {
            guard let meetingId = event.meetingId else { continue }

            let existingParticipants = try await database.persons.participants(inMeeting: meetingId)
            var linkedPersonIds = Set(existingParticipants.map(\.id))
            var existingNames = Set(existingParticipants.map(\.displayName))

            for attendee in event.attendees {
                let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = (attendee.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let hasEmail = !(email?.isEmpty ?? true)
                guard hasEmail || !displayName.isEmpty else { continue }

                // Email-less dedup: skip attendees whose name already matches an already-linked
                // participant of this meeting (the plan's tested divergence from `import.rs`,
                // which has no such guard) — re-runs never create duplicate name-only stubs.
                if !hasEmail, existingNames.contains(displayName) {
                    continue
                }

                let person = try await database.persons.upsertStubFromAttendee(
                    email: hasEmail ? email : nil,
                    displayName: displayName,
                    at: now
                )
                let alreadyLinked = linkedPersonIds.contains(person.id)
                try await database.persons.addParticipant(
                    meetingId: meetingId,
                    personId: person.id,
                    linkSource: "calendar",
                    at: now
                )
                linkedPersonIds.insert(person.id)
                existingNames.insert(person.displayName)
                if !alreadyLinked {
                    importedCount += 1
                }
            }
        }
        return importedCount
    }

    private static func asCalendarEvent(_ native: NativeEvent) -> CalendarEvent {
        CalendarEvent(
            id: CalendarEventID(native.id),
            calendarId: native.calendarId,
            calendarTitle: native.calendarTitle,
            title: native.title,
            startTime: native.startTime,
            endTime: native.endTime,
            isAllDay: native.isAllDay,
            location: native.location,
            notes: native.notes,
            organizer: native.organizer,
            attendees: native.attendees,
            seriesKey: native.seriesKey,
            hasRecurrence: native.hasRecurrence,
            occurrenceDate: native.occurrenceDate,
            isDetached: native.isDetached
        )
    }
}
