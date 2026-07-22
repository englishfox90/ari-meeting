//
//  CalendarSettingsViewModelTests.swift — docs/plans/settings-ui.md §8 test 4.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("CalendarSettingsViewModel")
@MainActor
struct CalendarSettingsViewModelTests {
    @Test("no EventKit source ⇒ honest .notDetermined + empty list")
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
}
