//
//  LinkedCalendarEventViewModel.swift — the meeting-detail linked-calendar-event card's view model
//  (docs/plans/calendar-series-intelligence.md §2.4, Feature 3).
//
//  A thin, honest orchestration over `CalendarEventRepository`'s already-shipped Feature 4 reads/
//  writes (`linkedEvent(forMeeting:)`, `events(startingIn:)`, `setManualLink`, `unlinkMeeting`) —
//  no new persistence concepts, mirroring `AddToSeriesViewModel`'s shape exactly: a direct
//  `AppDatabase` dependency, a busy flag, honest `errorMessage`, and reload-on-success-only (a
//  reload after a failed write would run `load`, whose successful read clears `errorMessage`,
//  silently swallowing the write error before the UI shows it).
//
//  No-Fake-State: `event` is honestly `nil` (never a placeholder) until `load` resolves a real
//  linked row — including the case where the only "link" points at a tombstoned event, which
//  `linkedEvent(forMeeting:)` already excludes.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class LinkedCalendarEventViewModel {
    /// The meeting's linked calendar event, or `nil` — an honest "no linked event", never a
    /// placeholder.
    public private(set) var event: CalendarEvent?
    /// Picker candidates loaded by `loadCandidates(around:)` (±7 days around the meeting date).
    public private(set) var candidateEvents: [CalendarEvent] = []
    /// The real error text of the last failed read/write, or `nil`. Surfaced honestly in the UI.
    public private(set) var errorMessage: String?
    /// True while a link/unlink mutation is in flight, so the UI can disable its controls.
    public private(set) var isBusy = false

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Loads the meeting's linked event (if any). Honest `errorMessage` on a real read failure;
    /// leaves the previously loaded `event` intact rather than blanking it.
    public func load(meetingId: MeetingID) async {
        do {
            event = try await database.calendarEvents.linkedEvent(forMeeting: meetingId)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Loads picker candidates: non-tombstoned events starting within ±7 days of `meetingDate`.
    public func loadCandidates(around meetingDate: Date) async {
        let window: TimeInterval = 7 * 24 * 3600
        let range = meetingDate.addingTimeInterval(-window) ... meetingDate.addingTimeInterval(window)
        do {
            candidateEvents = try await database.calendarEvents.events(startingIn: range)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Manually links `eventId` to `meetingId`, then reloads. Per `CalendarEventRepository`'s
    /// strict-1:1 semantics (calendar-series-intelligence plan §2.1), a manual link steals from
    /// whatever the event — or the meeting — was previously linked to.
    public func link(eventId: CalendarEventID, meetingId: MeetingID) async {
        await mutate(meetingId: meetingId) {
            try await self.database.calendarEvents.setManualLink(eventId: eventId, meetingId: meetingId)
        }
    }

    /// Clears the current link, then reloads to the honest `nil` state. A no-op when there is no
    /// loaded event to unlink.
    public func unlink() async {
        guard let event, let meetingId = event.meetingId else { return }
        await mutate(meetingId: meetingId) {
            try await self.database.calendarEvents.unlinkMeeting(eventId: event.id)
        }
    }

    /// Runs a link/unlink mutation with a busy flag + honest error capture. Reloads ONLY on
    /// success — see the file header for why a reload-after-failure would swallow the error.
    private func mutate(meetingId: MeetingID, _ operation: () async throws -> Void) async {
        isBusy = true
        do {
            try await operation()
            isBusy = false
            await load(meetingId: meetingId)
        } catch {
            errorMessage = String(describing: error)
            isBusy = false
        }
    }
}
