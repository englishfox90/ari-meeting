//
//  CalendarSyncEngineTests.swift — Lane-1 acceptance tests (plan §6, tests 1-13).
//
//  Headless, `FakeCalendarSource`, in-memory DB. The frozen Rust behavior
//  (`frontend/src-tauri/src/calendar/{eventkit,sync,commands}.rs`,
//  `ari-engine/src/database/repositories/calendar.rs`) is the spec; the §4 parity list is encoded
//  test-by-test below.
//
import Foundation
import Testing
@testable import AriKit

@Suite("CalendarSyncEngine")
struct CalendarSyncEngineTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func nativeEvent(
        id: String,
        calendarId: String = "cal-1",
        title: String = "Sync",
        start: Date,
        end: Date,
        notes: String? = nil,
        attendees: [Attendee] = []
    ) -> NativeEvent {
        NativeEvent(
            id: id,
            calendarId: calendarId,
            calendarTitle: "Work",
            title: title,
            startTime: start,
            endTime: end,
            isAllDay: false,
            notes: notes,
            attendees: attendees
        )
    }

    private func calendarEvent(
        id: CalendarEventID,
        calendarId: String = "cal-1",
        title: String = "Sync",
        start: Date,
        end: Date,
        attendees: [Attendee] = []
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            calendarId: calendarId,
            calendarTitle: "Work",
            title: title,
            startTime: start,
            endTime: end,
            isAllDay: false,
            attendees: attendees
        )
    }

    private func meeting(id: MeetingID, createdAt: Date) -> Meeting {
        Meeting(id: id, title: "Recording", createdAt: createdAt, updatedAt: createdAt)
    }

    // MARK: - 1. syncUpsert descriptive-field round trip

    @Test("sync upsert inserts then updates descriptive fields, stamping syncedAt")
    func syncUpsertInsertsAndUpdatesDescriptiveFields() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )

        let start = base
        let end = base.addingTimeInterval(1800)
        let source = FakeCalendarSource(events: [
            nativeEvent(id: "ev-1", title: "Weekly Sync", start: start, end: end)
        ])
        let engine = CalendarSyncEngine(source: source, database: db)

        let firstSyncAt = base.addingTimeInterval(-3600)
        let firstReport = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: firstSyncAt
        )
        #expect(firstReport.fetched == 1)

        let inserted = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(inserted.title == "Weekly Sync")

        await source.setEvents([
            nativeEvent(
                id: "ev-1", title: "Weekly Sync (Renamed)", start: start, end: end,
                notes: "New agenda item"
            )
        ])
        let secondSyncAt = base.addingTimeInterval(-1800)
        _ = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: secondSyncAt
        )

        let updated = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(updated.title == "Weekly Sync (Renamed)")
        #expect(updated.notes == "New agenda item")

        let record = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-1")
        }
        #expect(record?.syncedAt == secondSyncAt)
    }

    // MARK: - 2/3. Sync never clobbers a manual or auto link

    @Test("sync never clobbers a manual link")
    func syncNeverClobbersManualLink() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )
        let meetingId: MeetingID = "meeting-manual"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))

        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base.addingTimeInterval(-7200)
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)

        let source = FakeCalendarSource(events: [
            nativeEvent(id: "ev-1", title: "Weekly Sync (Renamed)", start: start, end: end)
        ])
        let engine = CalendarSyncEngine(source: source, database: db)
        _ = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.title == "Weekly Sync (Renamed)")
        #expect(event.meetingId == meetingId)
        #expect(event.linkSource == .manual)
    }

    @Test("sync never clobbers an auto link")
    func syncNeverClobbersAutoLink() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )
        let meetingId: MeetingID = "meeting-auto"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))

        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base.addingTimeInterval(-7200)
        )
        try await db.calendarEvents.setAutoLink(eventId: "ev-1", meetingId: meetingId)

        let source = FakeCalendarSource(events: [
            nativeEvent(id: "ev-1", title: "Weekly Sync (Renamed)", start: start, end: end)
        ])
        let engine = CalendarSyncEngine(source: source, database: db)
        _ = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.title == "Weekly Sync (Renamed)")
        #expect(event.meetingId == meetingId)
        #expect(event.linkSource == .auto)
    }

    // MARK: - 4/5/6. Prune semantics

    @Test("prune tombstones only missing events within range; outside-range events untouched")
    func pruneTombstonesOnlyMissingEventsInRange() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )

        let inRangeStart = base
        let inRangeEnd = base.addingTimeInterval(1800)
        let outsideStart = base.addingTimeInterval(10 * 24 * 3600)
        let outsideEnd = outsideStart.addingTimeInterval(1800)

        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-missing", start: inRangeStart, end: inRangeEnd),
                calendarEvent(id: "ev-outside", start: outsideStart, end: outsideEnd)
            ],
            at: base.addingTimeInterval(-7200)
        )

        let source = FakeCalendarSource(events: [])
        let engine = CalendarSyncEngine(source: source, database: db)
        let report = try await engine.syncRange(
            from: inRangeStart.addingTimeInterval(-3600), to: inRangeEnd.addingTimeInterval(3600), now: base
        )

        #expect(report.pruned == 1)

        let missingRecord = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-missing")
        }
        #expect(missingRecord?.isDeleted == true)
        #expect(missingRecord?.deletedAt == base)

        let outsideRecord = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-outside")
        }
        #expect(outsideRecord?.isDeleted == false)
    }

    @Test("a pruned event reappearing in a later sync is un-tombstoned")
    func prunedEventReappearingIsUntombstoned() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )
        let start = base
        let end = base.addingTimeInterval(1800)

        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base.addingTimeInterval(-7200)
        )

        let source = FakeCalendarSource(events: [])
        let engine = CalendarSyncEngine(source: source, database: db)
        let firstReport = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )
        #expect(firstReport.pruned == 1)

        let tombstoned = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-1")
        }
        #expect(tombstoned?.isDeleted == true)

        await source.setEvents([nativeEvent(id: "ev-1", title: "Weekly Sync", start: start, end: end)])
        let secondReport = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600),
            now: base.addingTimeInterval(60)
        )
        #expect(secondReport.pruned == 0)

        let revived = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-1")
        }
        #expect(revived?.isDeleted == false)
        #expect(revived?.deletedAt == nil)
    }

    @Test("an empty fetch prunes the whole range (frozen-parity edge, recoverable via un-tombstoning)")
    func emptyFetchPrunesWholeRange() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )
        let start = base
        let end = base.addingTimeInterval(3600)
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-a", start: start, end: start.addingTimeInterval(900)),
                calendarEvent(id: "ev-b", start: start.addingTimeInterval(1200), end: end)
            ],
            at: base.addingTimeInterval(-7200)
        )

        let source = FakeCalendarSource(events: [])
        let engine = CalendarSyncEngine(source: source, database: db)
        let report = try await engine.syncRange(from: start, to: end, now: base)

        #expect(report.fetched == 0)
        #expect(report.pruned == 2)
    }

    // MARK: - 7/8/9. Auto-match

    @Test("auto-match links the closest meeting within the 15-min slack window")
    func autoMatchLinksClosestMeetingWithin15MinSlack() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )

        let start = base
        let end = base.addingTimeInterval(1800)
        let farMeeting: MeetingID = "meeting-far"
        let nearMeeting: MeetingID = "meeting-near"
        try await db.meetings.upsert(meeting(id: farMeeting, createdAt: start.addingTimeInterval(-600)))
        try await db.meetings.upsert(meeting(id: nearMeeting, createdAt: start.addingTimeInterval(-120)))

        let source = FakeCalendarSource(events: [nativeEvent(id: "ev-1", start: start, end: end)])
        let engine = CalendarSyncEngine(source: source, database: db)
        let report = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )

        #expect(report.autoLinked == 1)
        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == nearMeeting)
        #expect(event.linkSource == .auto)
    }

    @Test("auto-match excludes a meeting outside the 15-min slack (pins the slack constant)")
    func autoMatchExcludesMeetingOutside15MinSlack() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )

        let start = base
        let end = base.addingTimeInterval(1800)
        // 20 min before event.start — outside the [start − 15 min, end + 15 min] window.
        // The only candidate, so a too-loose slack constant would link it and fail here.
        try await db.meetings.upsert(meeting(id: "meeting-outside", createdAt: start.addingTimeInterval(-1200)))

        let source = FakeCalendarSource(events: [nativeEvent(id: "ev-1", start: start, end: end)])
        let engine = CalendarSyncEngine(source: source, database: db)
        let report = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )

        #expect(report.autoLinked == 0)
        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == nil)
        #expect(event.linkSource == nil)
    }

    @Test("auto-match never touches a manual link, but re-points an auto link at a closer meeting")
    func autoMatchSkipsManualAndReevaluatesAuto() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )

        let start = base
        let end = base.addingTimeInterval(1800)
        let manualMeeting: MeetingID = "meeting-manual"
        let oldAuto: MeetingID = "meeting-old-auto"
        let newAuto: MeetingID = "meeting-new-auto"
        try await db.meetings.upsert(meeting(id: manualMeeting, createdAt: start.addingTimeInterval(-60)))
        try await db.meetings.upsert(meeting(id: oldAuto, createdAt: start.addingTimeInterval(-600)))
        try await db.meetings.upsert(meeting(id: newAuto, createdAt: start.addingTimeInterval(-30)))

        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-manual", start: start, end: end)], at: base.addingTimeInterval(-7200)
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-manual", meetingId: manualMeeting)

        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-auto", start: start, end: end)], at: base.addingTimeInterval(-7200)
        )
        try await db.calendarEvents.setAutoLink(eventId: "ev-auto", meetingId: oldAuto)

        let source = FakeCalendarSource(events: [
            nativeEvent(id: "ev-manual", start: start, end: end),
            nativeEvent(id: "ev-auto", start: start, end: end)
        ])
        let engine = CalendarSyncEngine(source: source, database: db)
        _ = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )

        let manualEvent = try #require(try await db.calendarEvents.find("ev-manual"))
        #expect(manualEvent.meetingId == manualMeeting)
        #expect(manualEvent.linkSource == .manual)

        let autoEvent = try #require(try await db.calendarEvents.find("ev-auto"))
        #expect(autoEvent.meetingId == newAuto)
        #expect(autoEvent.linkSource == .auto)
    }

    @Test("auto-match leaves an existing auto link as-is when no candidate meeting is found")
    func autoMatchLeavesExistingAutoLinkWhenNoCandidate() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )

        let start = base
        let end = base.addingTimeInterval(1800)
        let existingMeeting: MeetingID = "meeting-existing"
        try await db.meetings.upsert(meeting(id: existingMeeting, createdAt: start.addingTimeInterval(-60)))

        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base.addingTimeInterval(-7200)
        )
        try await db.calendarEvents.setAutoLink(eventId: "ev-1", meetingId: existingMeeting)

        // The previously-matched meeting is later removed (tombstoned) — no candidate remains in
        // the window, but the existing auto link must survive untouched.
        try await db.meetings.softDelete(existingMeeting, at: base)

        let source = FakeCalendarSource(events: [nativeEvent(id: "ev-1", start: start, end: end)])
        let engine = CalendarSyncEngine(source: source, database: db)
        let report = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )

        #expect(report.autoLinked == 0)
        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == existingMeeting)
        #expect(event.linkSource == .auto)
    }

    // MARK: - 10. Selection gates sync

    @Test("only selected calendars are fetched — an unselected calendar's events never sync")
    func unselectedCalendarsDoNotSync() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-selected", calendarTitle: "Work", color: nil, selected: true
        )
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-unselected", calendarTitle: "Personal", color: nil, selected: false
        )

        let start = base
        let end = base.addingTimeInterval(1800)
        let source = FakeCalendarSource(events: [
            nativeEvent(id: "ev-selected", calendarId: "cal-selected", start: start, end: end),
            nativeEvent(id: "ev-unselected", calendarId: "cal-unselected", start: start, end: end)
        ])
        let engine = CalendarSyncEngine(source: source, database: db)
        let report = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )

        #expect(report.fetched == 1)
        #expect(try await db.calendarEvents.find("ev-selected") != nil)
        #expect(try await db.calendarEvents.find("ev-unselected") == nil)

        let calls = await source.fetchCalls
        #expect(calls.first?.ids == ["cal-selected"])
    }

    @Test("identity refresh inserts a newly seen calendar as unselected")
    func newCalendarDefaultsUnselected() async throws {
        let db = try AppDatabase.makeInMemory()
        let source = FakeCalendarSource(
            calendars: [NativeCalendar(id: "cal-new", title: "New Calendar", color: "#112233")]
        )
        let engine = CalendarSyncEngine(source: source, database: db)

        let rows = try await engine.refreshCalendarList()
        #expect(rows.count == 1)
        #expect(rows[0].calendarId == "cal-new")
        #expect(rows[0].selected == false)

        let selectedIds = try await db.calendarEvents.selectedCalendarIds()
        #expect(selectedIds.isEmpty)
    }

    // MARK: - 11. Identity refresh preserves selection

    @Test("identity refresh updates title/color but preserves an existing selection")
    func refreshCalendarListPreservesSelection() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work (old)", color: "#000000", selected: true
        )

        let source = FakeCalendarSource(
            calendars: [NativeCalendar(id: "cal-1", title: "Work (renamed)", color: "#E8A020")]
        )
        let engine = CalendarSyncEngine(source: source, database: db)

        let rows = try await engine.refreshCalendarList()
        #expect(rows.count == 1)
        #expect(rows[0].calendarTitle == "Work (renamed)")
        #expect(rows[0].color == "#E8A020")
        #expect(rows[0].selected == true)
    }

    // MARK: - 12. Identifier-less events never reach the engine

    @Test("events without an identifier are skipped before the engine ever sees them (source contract)")
    func eventsWithoutIdentifierAreSkippedBeforeEngine() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )

        let start = base
        let end = base.addingTimeInterval(1800)
        let source = FakeCalendarSource(events: [
            nativeEvent(id: "", title: "No identifier", start: start, end: end),
            nativeEvent(id: "ev-valid", title: "Has identifier", start: start, end: end)
        ])
        let engine = CalendarSyncEngine(source: source, database: db)
        let report = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )

        #expect(report.fetched == 1)
        #expect(try await db.calendarEvents.find("ev-valid") != nil)
        #expect(try await db.calendarEvents.all().count == 1)
    }

    // MARK: - 13. Hint-seam confirmation

    @Test("after a sync auto-links an event with 3 attendees, the stored calendar hint provider returns it live")
    func storedCalendarHintGoesLiveAfterSync() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )

        let start = base
        let end = base.addingTimeInterval(1800)
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: start.addingTimeInterval(-30)))

        let attendees = (0 ..< 3).map { Attendee(name: "Guest \($0)") }
        let source = FakeCalendarSource(events: [
            nativeEvent(id: "ev-1", start: start, end: end, attendees: attendees)
        ])
        let engine = CalendarSyncEngine(source: source, database: db)
        let report = try await engine.syncRange(
            from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600), now: base
        )
        #expect(report.autoLinked == 1)

        let provider = StoredCalendarHintProvider(database: db)
        let resolved = try #require(await provider.hint(for: meetingId))
        #expect(resolved.hint == .upperBound(3))
        #expect(resolved.origin == .calendarAttendees)
    }
}
