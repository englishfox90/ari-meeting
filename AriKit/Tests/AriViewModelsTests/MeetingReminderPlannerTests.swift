//
//  MeetingReminderPlannerTests.swift — the pure reconciliation core (calendar reminders / F5).
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("MeetingReminderPlanner")
struct MeetingReminderPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func event(
        id: CalendarEventID,
        title: String = "Standup",
        startOffset: TimeInterval,
        isAllDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            calendarId: "cal-1",
            title: title,
            startTime: now.addingTimeInterval(startOffset),
            endTime: now.addingTimeInterval(startOffset + 1800),
            isAllDay: isAllDay,
            attendees: []
        )
    }

    @Test("schedules a reminder for a future event, firing lead-time before start")
    func schedulesFutureEvent() throws {
        let lead = Duration.seconds(5 * 60)
        // Event starts in 30 min → reminder fires 25 min from now.
        let events = [event(id: "ev-1", startOffset: 30 * 60)]
        let plan = MeetingReminderPlanner.plan(
            events: events, leadTime: lead, now: now, currentlyScheduled: []
        )

        #expect(plan.toCancel.isEmpty)
        #expect(plan.toSchedule.count == 1)
        let request = try #require(plan.toSchedule.first)
        #expect(request.id == MeetingReminderPlanner.identifier(for: "ev-1"))
        #expect(request.category == .meetingReminder)
        #expect(request.userInfo[NotificationUserInfoKey.eventId] == "ev-1")
        if case let .date(fireDate) = request.trigger {
            #expect(fireDate == now.addingTimeInterval(25 * 60))
        } else {
            Issue.record("expected a .date trigger")
        }
    }

    @Test("skips an event whose reminder moment already passed")
    func skipsPastReminder() {
        let lead = Duration.seconds(5 * 60)
        // Starts in 2 min, lead 5 min → fire time is 3 min in the PAST.
        let plan = MeetingReminderPlanner.plan(
            events: [event(id: "ev-1", startOffset: 2 * 60)],
            leadTime: lead, now: now, currentlyScheduled: []
        )
        #expect(plan.toSchedule.isEmpty)
        #expect(plan.toCancel.isEmpty)
    }

    @Test("skips all-day events")
    func skipsAllDay() {
        let plan = MeetingReminderPlanner.plan(
            events: [event(id: "ev-1", startOffset: 60 * 60, isAllDay: true)],
            leadTime: .seconds(5 * 60), now: now, currentlyScheduled: []
        )
        #expect(plan.toSchedule.isEmpty)
    }

    @Test("leaves an already-scheduled reminder untouched (no re-post)")
    func leavesAlreadyScheduled() {
        let id = MeetingReminderPlanner.identifier(for: "ev-1")
        let plan = MeetingReminderPlanner.plan(
            events: [event(id: "ev-1", startOffset: 30 * 60)],
            leadTime: .seconds(5 * 60), now: now, currentlyScheduled: [id]
        )
        #expect(plan.toSchedule.isEmpty)
        #expect(plan.toCancel.isEmpty)
    }

    @Test("cancels a pending reminder whose event is no longer desired")
    func cancelsRemovedEvent() {
        let staleId = MeetingReminderPlanner.identifier(for: "ev-gone")
        // ev-1 is still desired (future); ev-gone is no longer in the event set.
        let plan = MeetingReminderPlanner.plan(
            events: [event(id: "ev-1", startOffset: 30 * 60)],
            leadTime: .seconds(5 * 60), now: now, currentlyScheduled: [staleId]
        )
        #expect(plan.toSchedule.count == 1)
        #expect(plan.toCancel == [staleId])
    }

    @Test("de-duplicates repeated event ids into a single scheduled reminder")
    func dedupesDuplicateIds() {
        let events = [
            event(id: "ev-1", startOffset: 30 * 60),
            event(id: "ev-1", startOffset: 30 * 60),
        ]
        let plan = MeetingReminderPlanner.plan(
            events: events, leadTime: .seconds(5 * 60), now: now, currentlyScheduled: []
        )
        #expect(plan.toSchedule.count == 1)
    }

    @Test("a zero lead time fires exactly at start")
    func zeroLeadFiresAtStart() {
        let plan = MeetingReminderPlanner.plan(
            events: [event(id: "ev-1", startOffset: 10 * 60)],
            leadTime: .seconds(0), now: now, currentlyScheduled: []
        )
        if case let .date(fireDate) = plan.toSchedule.first?.trigger {
            #expect(fireDate == now.addingTimeInterval(10 * 60))
        } else {
            Issue.record("expected a .date trigger")
        }
    }
}
