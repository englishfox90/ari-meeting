//
//  NotchUpcomingPlannerTests.swift — the 12 Rust `due_events` cases ported one-for-one
//  (`frontend/src-tauri/src/notch/scheduler.rs:333-536`), plus the documented all-day divergence
//  (docs/plans/notch-panel-absorption.md Amendment A §A.6 suite 8).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("NotchUpcomingPlanner")
struct NotchUpcomingPlannerTests {
    private static let leads = [15, 5]

    /// Mirrors the Rust tests' `ev(id, start, has_meeting)` helper.
    private func ev(
        _ id: String,
        start: Date,
        hasMeeting: Bool = false,
        isAllDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: CalendarEventID(id),
            calendarId: "cal-1",
            title: "Meeting \(id)",
            startTime: start,
            endTime: start.addingTimeInterval(3600),
            isAllDay: isAllDay,
            attendees: [Attendee(name: "A"), Attendee(name: "B"), Attendee(name: "C")],
            meetingId: hasMeeting ? MeetingID("meeting-\(id)") : nil
        )
    }

    /// Mirrors the Rust tests' fixed anchor "meeting start" (`base()`, scheduler.rs:347-352).
    private static let base: Date = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: "2026-07-14T10:00:00Z")!
    }()

    @Test("firesExactlyAtTMinus15")
    func firesExactlyAtTMinus15() {
        let start = Self.base
        let now = start.addingTimeInterval(-15 * 60)
        let events = [ev("E1", start: start)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: [], dismissed: []
        )
        #expect(decision.fire == [.init(eventId: "E1", leadMinutes: 15)])
        #expect(decision.dismiss.isEmpty)
    }

    @Test("firesExactlyAtTMinus5")
    func firesExactlyAtTMinus5() {
        let start = Self.base
        let now = start.addingTimeInterval(-5 * 60)
        let events = [ev("E1", start: start)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: [], dismissed: []
        )
        #expect(decision.fire == [.init(eventId: "E1", leadMinutes: 5)])
    }

    @Test("noFireEarlierThanTolerance")
    func noFireEarlierThanTolerance() {
        let start = Self.base
        // 15m + 120s before start: just outside the T-15 tolerance window (45s).
        let now = start.addingTimeInterval(-15 * 60 - 120)
        let events = [ev("E1", start: start)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: [], dismissed: []
        )
        #expect(decision.fire.isEmpty, "must not fire before the tolerance window")
        #expect(decision.dismiss.isEmpty)
    }

    @Test("noDuplicateFireWhenAlreadyInFiredSet")
    func noDuplicateFireWhenAlreadyInFiredSet() {
        let start = Self.base
        let now = start.addingTimeInterval(-15 * 60)
        let events = [ev("E1", start: start)]
        let fired: Set<NotchUpcomingPlanner.Fire> = [.init(eventId: "E1", leadMinutes: 15)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: fired, dismissed: []
        )
        #expect(decision.fire.isEmpty, "second tick in the window must not re-fire")
    }

    @Test("noFireForEventThatAlreadyHasMeeting")
    func noFireForEventThatAlreadyHasMeeting() {
        let start = Self.base
        let now = start.addingTimeInterval(-15 * 60)
        let events = [ev("E1", start: start, hasMeeting: true)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: [], dismissed: []
        )
        #expect(decision.fire.isEmpty, "recorded events never fire a reminder")
    }

    @Test("noDismissWhileLingeringAfterStart")
    func noDismissWhileLingeringAfterStart() {
        let start = Self.base
        // Start just passed but still inside the linger grace window.
        let now = start.addingTimeInterval(1)
        let events = [ev("E1", start: start)]
        let fired: Set<NotchUpcomingPlanner.Fire> = [.init(eventId: "E1", leadMinutes: 5)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: fired, dismissed: []
        )
        #expect(decision.dismiss.isEmpty, "prompt must linger past start for the late-user grace window")
        #expect(decision.fire.isEmpty, "no new reminders fire after start")
    }

    @Test("dismissOnceLingerWindowExpires")
    func dismissOnceLingerWindowExpires() {
        let start = Self.base
        // Just past the linger grace window.
        let now = start.addingTimeInterval(NotchUpcomingPlanner.lingerAfterStart + 1)
        let events = [ev("E1", start: start)]
        let fired: Set<NotchUpcomingPlanner.Fire> = [.init(eventId: "E1", leadMinutes: 5)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: fired, dismissed: []
        )
        #expect(decision.dismiss == ["E1"])
        #expect(decision.fire.isEmpty)
    }

    @Test("dismissWhenEventGainsMeeting")
    func dismissWhenEventGainsMeeting() {
        let start = Self.base
        let now = start.addingTimeInterval(-4 * 60) // still before start
        let events = [ev("E1", start: start, hasMeeting: true)] // got recorded
        let fired: Set<NotchUpcomingPlanner.Fire> = [.init(eventId: "E1", leadMinutes: 5)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: fired, dismissed: []
        )
        #expect(decision.dismiss == ["E1"])
    }

    @Test("dismissWhenEventVanishesFromRange")
    func dismissWhenEventVanishesFromRange() {
        let now = Self.base
        // E1 was fired earlier but is absent from this tick's events (cancelled).
        let events: [CalendarEvent] = []
        let fired: Set<NotchUpcomingPlanner.Fire> = [.init(eventId: "E1", leadMinutes: 15)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: fired, dismissed: []
        )
        #expect(decision.dismiss == ["E1"])
    }

    @Test("noRedundantDismissWhenAlreadyDismissed")
    func noRedundantDismissWhenAlreadyDismissed() {
        let start = Self.base
        let now = start.addingTimeInterval(NotchUpcomingPlanner.lingerAfterStart + 1)
        let events = [ev("E1", start: start)]
        let fired: Set<NotchUpcomingPlanner.Fire> = [.init(eventId: "E1", leadMinutes: 5)]
        let dismissed: Set<CalendarEventID> = ["E1"]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: fired, dismissed: dismissed
        )
        #expect(decision.dismiss.isEmpty, "already-dismissed events don't re-emit")
    }

    @Test("vanishedEventDismissedOnceAcrossMultipleFiredLeads")
    func vanishedEventDismissedOnceAcrossMultipleFiredLeads() {
        let now = Self.base
        let events: [CalendarEvent] = []
        let fired: Set<NotchUpcomingPlanner.Fire> = [
            .init(eventId: "E1", leadMinutes: 15),
            .init(eventId: "E1", leadMinutes: 5),
        ]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: fired, dismissed: []
        )
        #expect(decision.dismiss == ["E1"], "one dismiss per event id")
    }

    @Test("fullLifecycleT15ThenT5ThenDismiss")
    func fullLifecycleT15ThenT5ThenDismiss() {
        let start = Self.base
        let events = [ev("E1", start: start)]
        var fired: Set<NotchUpcomingPlanner.Fire> = []
        let dismissed: Set<CalendarEventID> = []

        // Tick 1: T-15 → fire (15).
        let r1 = NotchUpcomingPlanner.dueEvents(
            now: start.addingTimeInterval(-15 * 60),
            events: events, leadsMinutes: Self.leads, fired: fired, dismissed: dismissed
        )
        #expect(r1.fire == [.init(eventId: "E1", leadMinutes: 15)])
        fired.formUnion(r1.fire)

        // Tick 2: T-5 → fire (5), no re-fire of 15.
        let r2 = NotchUpcomingPlanner.dueEvents(
            now: start.addingTimeInterval(-5 * 60),
            events: events, leadsMinutes: Self.leads, fired: fired, dismissed: dismissed
        )
        #expect(r2.fire == [.init(eventId: "E1", leadMinutes: 5)])
        fired.formUnion(r2.fire)

        // Tick 3: start just passed, still lingering → no dismiss, no fire.
        let r3 = NotchUpcomingPlanner.dueEvents(
            now: start.addingTimeInterval(2),
            events: events, leadsMinutes: Self.leads, fired: fired, dismissed: dismissed
        )
        #expect(r3.fire.isEmpty)
        #expect(r3.dismiss.isEmpty, "prompt lingers through the grace window")

        // Tick 4: grace window expired → dismiss, no fire.
        let r4 = NotchUpcomingPlanner.dueEvents(
            now: start.addingTimeInterval(NotchUpcomingPlanner.lingerAfterStart + 2),
            events: events, leadsMinutes: Self.leads, fired: fired, dismissed: dismissed
        )
        #expect(r4.fire.isEmpty)
        #expect(r4.dismiss == ["E1"])
    }

    // MARK: - Swift-only divergence (documented, deliberate — file header)

    @Test("allDayEventsNeverFire")
    func allDayEventsNeverFire() {
        let start = Self.base
        let now = start.addingTimeInterval(-15 * 60)
        let events = [ev("E1", start: start, isAllDay: true)]
        let decision = NotchUpcomingPlanner.dueEvents(
            now: now, events: events, leadsMinutes: Self.leads, fired: [], dismissed: []
        )
        #expect(decision.fire.isEmpty, "all-day events must never fire — the one deliberate divergence from Rust")
        #expect(decision.dismiss.isEmpty)
    }
}
