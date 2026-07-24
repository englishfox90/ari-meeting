//
//  LinkedCalendarEventViewModelTests.swift — docs/plans/calendar-series-intelligence.md §5,
//  tests 26-28.
//
//  Exercises the real in-memory `AppDatabase` through `CalendarEventRepository` (the same pattern
//  as `AddToSeriesViewModelTests`): load honestly reflects the persisted linked event (including
//  the tombstoned-competitor case), unlink/link round-trip through the VM, and error paths leave
//  prior state intact.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("LinkedCalendarEventViewModel")
@MainActor
struct LinkedCalendarEventViewModelTests {
    private let meetingId: MeetingID = "meeting-1"
    private let otherMeetingId: MeetingID = "meeting-2"
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDatabase() async throws -> AppDatabase {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(Meeting(id: meetingId, title: "Preston 1:1", createdAt: base, updatedAt: base))
        try await db.meetings.upsert(Meeting(id: otherMeetingId, title: "Standup", createdAt: base, updatedAt: base))
        return db
    }

    private func calendarEvent(
        id: CalendarEventID,
        title: String = "Preston 1:1",
        start: Date,
        end: Date
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, calendarId: "cal-1", calendarTitle: "Work", title: title,
            startTime: start, endTime: end, isAllDay: false, attendees: []
        )
    }

    // MARK: - Test 26: load honesty

    @Test("load returns the linked event, and nil when none")
    func loadReturnsLinkedEventOrNil() async throws {
        let db = try await makeDatabase()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert([calendarEvent(id: "ev-1", start: start, end: end)], at: base)
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)

        let vm = LinkedCalendarEventViewModel(database: db)
        await vm.load(meetingId: meetingId)
        #expect(vm.event?.id == "ev-1")
        #expect(vm.errorMessage == nil)

        await vm.load(meetingId: otherMeetingId)
        #expect(vm.event == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test("load returns nil when the only link is on a tombstoned event")
    func loadReturnsNilForTombstonedLink() async throws {
        let db = try await makeDatabase()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert([calendarEvent(id: "ev-1", start: start, end: end)], at: base)
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)
        try await db.calendarEvents.softDelete("ev-1", at: base)

        let vm = LinkedCalendarEventViewModel(database: db)
        await vm.load(meetingId: meetingId)
        #expect(vm.event == nil)
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Test 27: unlink / link round-trip, steal semantics

    @Test("unlink clears the link and reloads to nil")
    func unlinkClearsAndReloads() async throws {
        let db = try await makeDatabase()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert([calendarEvent(id: "ev-1", start: start, end: end)], at: base)
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)

        let vm = LinkedCalendarEventViewModel(database: db)
        await vm.load(meetingId: meetingId)
        #expect(vm.event?.id == "ev-1")

        await vm.unlink()
        #expect(vm.event == nil)
        #expect(try await db.calendarEvents.find("ev-1")?.meetingId == nil)
    }

    @Test("unlink with no loaded event is a no-op")
    func unlinkNoOpWithoutLoadedEvent() async throws {
        let db = try await makeDatabase()
        let vm = LinkedCalendarEventViewModel(database: db)
        await vm.load(meetingId: meetingId)
        #expect(vm.event == nil)

        await vm.unlink()
        #expect(vm.event == nil)
        #expect(vm.errorMessage == nil)
        #expect(vm.isBusy == false)
    }

    @Test("link sets a manual link and steals from a previously linked event")
    func linkStealsFromPreviouslyLinkedEvent() async throws {
        let db = try await makeDatabase()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-old", start: start, end: end),
                calendarEvent(id: "ev-new", start: start, end: end)
            ],
            at: base
        )
        // ev-old is already linked to meetingId; linking ev-new should steal the link.
        try await db.calendarEvents.setManualLink(eventId: "ev-old", meetingId: meetingId)

        let vm = LinkedCalendarEventViewModel(database: db)
        await vm.load(meetingId: meetingId)
        #expect(vm.event?.id == "ev-old")

        await vm.link(eventId: "ev-new", meetingId: meetingId)
        #expect(vm.event?.id == "ev-new")
        #expect(try await db.calendarEvents.find("ev-old")?.meetingId == nil)
        #expect(try await db.calendarEvents.find("ev-new")?.meetingId == meetingId)
    }

    @Test("loadCandidates loads events within a 7-day window of the given date")
    func loadCandidatesUsesSevenDayWindow() async throws {
        let db = try await makeDatabase()
        let inWindow = base.addingTimeInterval(3 * 24 * 3600)
        let outOfWindow = base.addingTimeInterval(10 * 24 * 3600)
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-near", title: "Near", start: inWindow, end: inWindow.addingTimeInterval(1800)),
                calendarEvent(id: "ev-far", title: "Far", start: outOfWindow, end: outOfWindow.addingTimeInterval(1800))
            ],
            at: base
        )

        let vm = LinkedCalendarEventViewModel(database: db)
        await vm.loadCandidates(around: base)
        #expect(vm.candidateEvents.map(\.id) == ["ev-near"])
    }

    // MARK: - Test 28: error paths keep prior state

    @Test("a failed link surfaces errorMessage honestly and keeps prior event state")
    func failedLinkKeepsPriorState() async throws {
        let db = try await makeDatabase()
        let start = base
        let end = base.addingTimeInterval(1800)
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-1", start: start, end: end),
                calendarEvent(id: "ev-2", start: start, end: end)
            ],
            at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-1", meetingId: meetingId)

        let vm = LinkedCalendarEventViewModel(database: db)
        await vm.load(meetingId: meetingId)
        #expect(vm.event?.id == "ev-1")

        // A nonexistent meeting id: the `meetingId` column has a foreign-key reference to
        // `meeting`, so this write genuinely throws (FK violation) rather than silently no-oping.
        await vm.link(eventId: "ev-2", meetingId: "no-such-meeting")
        #expect(vm.isBusy == false)
        #expect(vm.errorMessage != nil)
        // The reload was never reached (the write threw before it could succeed), so the prior
        // linked event is still reflected — the error never silently swallows real state.
        #expect(vm.event?.id == "ev-1")
        #expect(try await db.calendarEvents.find("ev-2")?.meetingId == nil)
    }
}
