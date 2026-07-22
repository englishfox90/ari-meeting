//
//  CalendarSettingsViewModelTests.swift — docs/plans/settings-ui.md §8 test 4, extended for the
//  S7 EventKit slice (docs/plans/arikit-calendar.md §6).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("CalendarSettingsViewModel")
@MainActor
struct CalendarSettingsViewModelTests {
    /// Re-scoped for S7: this test now specifically covers the NO-SOURCE-INJECTED path (headless
    /// construction — previews, and any call site that hasn't wired a real `CalendarSourcing`
    /// yet). `source == nil` is the honest-disabled trigger now, not "no EventKit source exists
    /// in the Swift app yet" — that source now exists (`EventKitCalendarSource`, C3) but this
    /// constructor overload simply doesn't receive one. The assertions are unchanged.
    @Test("no source injected ⇒ honest .notDetermined + empty list + disabled grant")
    func honestEmptyState() async throws {
        let database = try AppDatabase.makeInMemory()
        let viewModel = CalendarSettingsViewModel(database: database)
        await viewModel.load()

        #expect(viewModel.permission == .notDetermined)
        #expect(viewModel.calendars.isEmpty)

        guard case let .disabled(reason) = viewModel.grantAccessAvailability else {
            Issue.record("expected .disabled, got \(viewModel.grantAccessAvailability)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("setSelected round-trips through CalendarEventRepository")
    func setSelectedRoundTrips() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.calendarEvents.setSyncSetting(
            calendarId: "cal-1",
            calendarTitle: "Work",
            color: "#FF0000",
            selected: false
        )

        let viewModel = CalendarSettingsViewModel(database: database)
        await viewModel.load()
        #expect(viewModel.calendars.count == 1)
        #expect(viewModel.calendars[0].selected == false)

        try await viewModel.setSelected(true, for: "cal-1")
        #expect(viewModel.calendars[0].selected == true)

        let stored = try await database.calendarEvents.syncSettings()
        #expect(stored.first { $0.calendarId == "cal-1" }?.selected == true)
        // Title/color preserved through the round trip, not clobbered.
        #expect(stored.first { $0.calendarId == "cal-1" }?.calendarTitle == "Work")
    }

    @Test("grant access is live when a real source is injected")
    func grantAvailableWhenSourceInjected() async throws {
        let database = try AppDatabase.makeInMemory()
        let source = FakeCalendarSource(permission: .notDetermined)
        let viewModel = CalendarSettingsViewModel(database: database, source: source)

        guard case .live = viewModel.grantAccessAvailability else {
            Issue.record("expected .live, got \(viewModel.grantAccessAvailability)")
            return
        }
    }

    @Test("a denied source is reported honestly, never optimistically")
    func deniedPermissionReportedHonestly() async throws {
        let database = try AppDatabase.makeInMemory()
        let source = FakeCalendarSource(permission: .denied)
        let viewModel = CalendarSettingsViewModel(database: database, source: source)

        await viewModel.load()

        #expect(viewModel.permission == .denied)
        #expect(viewModel.calendars.isEmpty)
    }

    @Test("load() populates the calendar list live from the source when access is granted")
    func loadPopulatesCalendarsFromSourceWhenGranted() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Old Title", color: "#000000", selected: true
        )
        let source = FakeCalendarSource(
            permission: .fullAccess,
            calendars: [NativeCalendar(id: "cal-1", title: "New Title", color: "#E8A020")]
        )
        let viewModel = CalendarSettingsViewModel(database: database, source: source)

        await viewModel.load()

        #expect(viewModel.permission == .granted)
        #expect(viewModel.calendars.count == 1)
        #expect(viewModel.calendars[0].calendarTitle == "New Title")
        #expect(viewModel.calendars[0].color == "#E8A020")
        // Identity refresh preserves the existing selection (plan §4 item 6).
        #expect(viewModel.calendars[0].selected == true)
    }

    @Test("syncNow() surfaces the real sync report")
    func syncNowReportsRealCounts() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.calendarEvents.setSyncSetting(
            calendarId: "cal-1", calendarTitle: "Work", color: nil, selected: true
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = FakeCalendarSource(
            permission: .fullAccess,
            events: [
                NativeEvent(
                    id: "ev-1", calendarId: "cal-1", title: "Weekly Sync",
                    startTime: now, endTime: now.addingTimeInterval(1800), isAllDay: false
                )
            ]
        )
        let viewModel = CalendarSettingsViewModel(database: database, source: source)

        await viewModel.syncNow()

        let report = try #require(viewModel.lastSyncReport)
        #expect(report.fetched == 1)
        #expect(viewModel.lastSyncError == nil)
    }
}
