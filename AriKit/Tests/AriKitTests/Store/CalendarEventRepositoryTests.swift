//
//  CalendarEventRepositoryTests.swift — direct coverage of every S7 §2.3 addition to
//  `CalendarEventRepository` (docs/plans/arikit-calendar.md §6).
//
import Foundation
import Testing
@testable import AriKit

@Suite("CalendarEventRepository — S7 sync additions")
struct CalendarEventRepositoryTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func calendarEvent(
        id: CalendarEventID,
        calendarId: String = "cal-1",
        title: String = "Sync",
        start: Date,
        end: Date
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, calendarId: calendarId, calendarTitle: "Work", title: title,
            startTime: start, endTime: end, isAllDay: false, attendees: []
        )
    }

    private func meeting(id: MeetingID, createdAt: Date) -> Meeting {
        Meeting(id: id, title: "Recording", createdAt: createdAt, updatedAt: createdAt)
    }

    // MARK: - syncUpsert

    @Test("latestSyncedAt is nil before any sync, then tracks the newest syncedAt")
    func latestSyncedAtTracksNewestSync() async throws {
        let db = try AppDatabase.makeInMemory()
        #expect(try await db.calendarEvents.latestSyncedAt() == nil)

        let first = base
        let second = base.addingTimeInterval(900)
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: base, end: base.addingTimeInterval(1800))], at: first
        )
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-2", start: base, end: base.addingTimeInterval(1800))], at: second
        )

        let latest = try #require(try await db.calendarEvents.latestSyncedAt())
        #expect(abs(latest.timeIntervalSince(second)) < 0.01)
    }

    @Test("syncUpsert inserts a new row unlinked")
    func syncUpsertInsertsNewRow() async throws {
        let db = try AppDatabase.makeInMemory()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base
        )

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == nil)
        #expect(event.linkSource == nil)
        #expect(event.title == "Sync")
    }

    @Test("syncUpsert updates descriptive fields on an existing row without touching a link")
    func syncUpsertUpdatesDescriptiveFieldsPreservingLink() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))

        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base.addingTimeInterval(-3600)
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)

        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", title: "Renamed", start: start, end: end)], at: base
        )

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.title == "Renamed")
        #expect(event.meetingId == meetingId)
        #expect(event.linkSource == .manual)
    }

    @Test("syncUpsert un-tombstones a re-appearing event")
    func syncUpsertUnTombstonesReappearingEvent() async throws {
        let db = try AppDatabase.makeInMemory()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base.addingTimeInterval(-3600)
        )
        try await db.calendarEvents.softDelete("ev-1", at: base.addingTimeInterval(-1800))

        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base
        )

        let record = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-1")
        }
        #expect(record?.isDeleted == false)
        #expect(record?.deletedAt == nil)
    }

    // MARK: - pruneStaleEvents

    @Test("pruneStaleEvents tombstones only events outside the keep set")
    func pruneStaleEventsTombstonesOutOfKeepSet() async throws {
        let db = try AppDatabase.makeInMemory()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-keep", start: start, end: end),
                calendarEvent(id: "ev-prune", start: start, end: end)
            ],
            at: base.addingTimeInterval(-3600)
        )

        let pruned = try await db.calendarEvents.pruneStaleEvents(
            startingIn: start.addingTimeInterval(-60) ... end.addingTimeInterval(60),
            keeping: ["ev-keep"],
            at: base
        )
        #expect(pruned == 1)

        let keepRecord = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-keep")
        }
        #expect(keepRecord?.isDeleted == false)

        let prunedRecord = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-prune")
        }
        #expect(prunedRecord?.isDeleted == true)
        #expect(prunedRecord?.deletedAt == base)
    }

    @Test("pruneStaleEvents ignores events whose startTime falls outside the range")
    func pruneStaleEventsIgnoresEventsOutsideRange() async throws {
        let db = try AppDatabase.makeInMemory()
        let farStart = base.addingTimeInterval(30 * 24 * 3600)
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-far", start: farStart, end: farStart.addingTimeInterval(1800))],
            at: base.addingTimeInterval(-3600)
        )

        let pruned = try await db.calendarEvents.pruneStaleEvents(
            startingIn: base ... base.addingTimeInterval(3600),
            keeping: [],
            at: base
        )
        #expect(pruned == 0)

        let record = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-far")
        }
        #expect(record?.isDeleted == false)
    }

    // MARK: - events(startingIn:) / autoLinkableEvents(startingIn:)

    @Test("events(startingIn:) excludes tombstoned rows")
    func eventsStartingInRangeExcludesTombstoned() async throws {
        let db = try AppDatabase.makeInMemory()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-live", start: start, end: end),
                calendarEvent(id: "ev-dead", start: start, end: end)
            ],
            at: base
        )
        try await db.calendarEvents.softDelete("ev-dead", at: base)

        let events = try await db.calendarEvents
            .events(startingIn: start.addingTimeInterval(-60) ... end.addingTimeInterval(60))
        #expect(events.map(\.id) == ["ev-live"])
    }

    @Test("autoLinkableEvents excludes manually-linked rows")
    func autoLinkableEventsExcludesManual() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-unlinked", start: start, end: end),
                calendarEvent(id: "ev-auto", start: start, end: end),
                calendarEvent(id: "ev-manual", start: start, end: end)
            ],
            at: base
        )
        try await db.calendarEvents.setAutoLink(eventId: "ev-auto", meetingId: meetingId)
        try await db.calendarEvents.setManualLink(eventId: "ev-manual", meetingId: meetingId)

        let candidates = try await db.calendarEvents.autoLinkableEvents(
            startingIn: start.addingTimeInterval(-60) ... end.addingTimeInterval(60)
        )
        #expect(Set(candidates.map(\.id)) == ["ev-unlinked", "ev-auto"])
    }

    // MARK: - setAutoLink / setManualLink / unlinkMeeting

    @Test("setAutoLink writes meetingId + linkSource when the event isn't manually linked")
    func setAutoLinkWritesWhenNotManual() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: base, end: base.addingTimeInterval(1800))], at: base
        )

        try await db.calendarEvents.setAutoLink(eventId: "ev-1", meetingId: meetingId)

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == meetingId)
        #expect(event.linkSource == .auto)
    }

    @Test("setAutoLink is a no-op against an existing manual link (the manual guard)")
    func setAutoLinkGuardsAgainstExistingManualLink() async throws {
        let db = try AppDatabase.makeInMemory()
        let manualMeeting: MeetingID = "meeting-manual"
        let otherMeeting: MeetingID = "meeting-other"
        try await db.meetings.upsert(meeting(id: manualMeeting, createdAt: base))
        try await db.meetings.upsert(meeting(id: otherMeeting, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: base, end: base.addingTimeInterval(1800))], at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: manualMeeting)

        try await db.calendarEvents.setAutoLink(eventId: "ev-1", meetingId: otherMeeting)

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == manualMeeting)
        #expect(event.linkSource == .manual)
    }

    @Test("setManualLink always overrides an existing auto link")
    func setManualLinkOverridesExistingAutoLink() async throws {
        let db = try AppDatabase.makeInMemory()
        let autoMeeting: MeetingID = "meeting-auto"
        let manualMeeting: MeetingID = "meeting-manual"
        try await db.meetings.upsert(meeting(id: autoMeeting, createdAt: base))
        try await db.meetings.upsert(meeting(id: manualMeeting, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: base, end: base.addingTimeInterval(1800))], at: base
        )
        try await db.calendarEvents.setAutoLink(eventId: "ev-1", meetingId: autoMeeting)

        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: manualMeeting)

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == manualMeeting)
        #expect(event.linkSource == .manual)
    }

    @Test("unlinkMeeting clears meetingId and records the durable .unlinked sentinel")
    func unlinkMeetingClearsMeetingAndMarksUnlinked() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: base, end: base.addingTimeInterval(1800))], at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)

        try await db.calendarEvents.unlinkMeeting(eventId: "ev-1")

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == nil)
        #expect(event.linkSource == .unlinked)
    }

    // MARK: - Durable unlink (regression: unlink must survive the next auto-match pass)

    @Test("an unlinked event is not an auto-match candidate")
    func unlinkedEventIsExcludedFromAutoMatchCandidates() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: start, end: end)], at: base
        )
        try await db.calendarEvents.setAutoLink(eventId: "ev-1", meetingId: meetingId)
        try await db.calendarEvents.unlinkMeeting(eventId: "ev-1")

        let candidates = try await db.calendarEvents.autoLinkableEvents(
            startingIn: start.addingTimeInterval(-60) ... end.addingTimeInterval(60)
        )
        #expect(candidates.isEmpty)
    }

    @Test("setAutoLink is a no-op against an unlinked event (unlink survives re-matching)")
    func setAutoLinkGuardsAgainstUnlinkedEvent() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: base, end: base.addingTimeInterval(1800))], at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)
        try await db.calendarEvents.unlinkMeeting(eventId: "ev-1")

        // A stale candidate set could still call setAutoLink directly — it must refuse.
        try await db.calendarEvents.setAutoLink(eventId: "ev-1", meetingId: meetingId)

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == nil)
        #expect(event.linkSource == .unlinked)
    }

    @Test("a manual re-link overrides the .unlinked sentinel")
    func manualLinkOverridesUnlinkedSentinel() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-1", start: base, end: base.addingTimeInterval(1800))], at: base
        )
        try await db.calendarEvents.unlinkMeeting(eventId: "ev-1")

        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)

        let event = try #require(try await db.calendarEvents.find("ev-1"))
        #expect(event.meetingId == meetingId)
        #expect(event.linkSource == .manual)
    }

    // MARK: - selectedCalendarIds / setSelectedCalendars

    @Test("selectedCalendarIds returns only selected calendars")
    func selectedCalendarIdsReturnsOnlySelected() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(calendarId: "cal-a", calendarTitle: nil, color: nil, selected: true)
        try await db.calendarEvents.setSyncSetting(calendarId: "cal-b", calendarTitle: nil, color: nil, selected: false)

        let ids = try await db.calendarEvents.selectedCalendarIds()
        #expect(ids == ["cal-a"])
    }

    @Test("setSelectedCalendars clears every row then sets exactly the given ids, transactionally")
    func setSelectedCalendarsClearsThenSetsTransactionally() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(calendarId: "cal-a", calendarTitle: nil, color: nil, selected: true)
        try await db.calendarEvents.setSyncSetting(calendarId: "cal-b", calendarTitle: nil, color: nil, selected: false)
        try await db.calendarEvents.setSyncSetting(calendarId: "cal-c", calendarTitle: nil, color: nil, selected: true)

        try await db.calendarEvents.setSelectedCalendars(["cal-b"])

        let ids = try await db.calendarEvents.selectedCalendarIds()
        #expect(ids == ["cal-b"])
    }

    // MARK: - upsertCalendarIdentity

    @Test("upsertCalendarIdentity inserts a newly seen calendar as unselected")
    func upsertCalendarIdentityInsertsUnselected() async throws {
        let db = try AppDatabase.makeInMemory()
        let row = try await db.calendarEvents.upsertCalendarIdentity(
            calendarId: "cal-new", title: "New", color: "#112233"
        )
        #expect(row.calendarId == "cal-new")
        #expect(row.calendarTitle == "New")
        #expect(row.color == "#112233")
        #expect(row.selected == false)
    }

    @Test("upsertCalendarIdentity updates title/color but never resets an existing selection")
    func upsertCalendarIdentityPreservesExistingSelection() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Old", color: "#000000", selected: true
        )

        let row = try await db.calendarEvents.upsertCalendarIdentity(
            calendarId: "cal-1", title: "New Title", color: "#E8A020"
        )

        #expect(row.calendarTitle == "New Title")
        #expect(row.color == "#E8A020")
        #expect(row.selected == true)
    }
}
