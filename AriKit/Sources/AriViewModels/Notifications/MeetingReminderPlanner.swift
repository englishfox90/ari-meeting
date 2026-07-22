//
//  MeetingReminderPlanner.swift — the PURE reconciliation core for calendar reminders
//  (the Swift port of Rust F5, the calendar-triggered record prompt).
//
//  Given the synced calendar events, the configured lead time, "now", and the set of reminders
//  the OS currently has pending, it computes exactly which new reminders to schedule and which
//  stale ones to cancel. No I/O, no framework — so it is exhaustively unit-testable, and the
//  `MeetingNotifications` coordinator is a thin shell over it.
//
import AriKit
import Foundation

public enum MeetingReminderPlanner {
    /// The reconciliation delta: what to add and what to remove to make the OS's pending set match
    /// the desired set.
    public struct Plan: Equatable, Sendable {
        public var toSchedule: [NotificationRequest]
        public var toCancel: Set<String>

        public init(toSchedule: [NotificationRequest], toCancel: Set<String>) {
            self.toSchedule = toSchedule
            self.toCancel = toCancel
        }
    }

    /// The stable reminder identifier for an event (`MEETING_REMINDER.<eventId>`), so re-syncing the
    /// same event never double-schedules and a moved/removed event is cancellable by id.
    public static func identifier(for eventId: CalendarEventID) -> String {
        "\(NotificationCategory.meetingReminder.rawValue).\(eventId.rawValue)"
    }

    /// Compute the schedule/cancel delta.
    ///
    /// Rules (all No-Fake-State honest — a reminder exists iff a real future event warrants it):
    /// - **All-day events are skipped** — they have no meaningful "starts in N minutes" moment.
    /// - **Only future fire times** are scheduled: `startTime − leadTime` must be strictly after
    ///   `now`; an event whose reminder moment already passed is never (re)scheduled.
    /// - **Already-pending reminders are left untouched** (not re-posted) to avoid churn.
    /// - **`toCancel` = every currently-pending reminder that is no longer desired** — the event
    ///   was deleted, moved earlier than the lead window, or already fired-and-was-removed (in
    ///   which case it isn't in `currentlyScheduled` and so isn't cancelled spuriously).
    ///
    /// `currentlyScheduled` MUST contain only reminder identifiers the caller owns (the scheduler's
    /// `pendingReminderIdentifiers()` guarantees this by category prefix) so a cancel never reaches
    /// beyond meeting reminders.
    public static func plan(
        events: [CalendarEvent],
        leadTime: Duration,
        now: Date,
        currentlyScheduled: Set<String>
    ) -> Plan {
        let leadSeconds = Double(leadTime.components.seconds)
        var toSchedule: [NotificationRequest] = []
        var desired: Set<String> = []

        for event in events {
            guard !event.isAllDay else { continue }
            let fireDate = event.startTime.addingTimeInterval(-leadSeconds)
            guard fireDate > now else { continue }

            let id = identifier(for: event.id)
            // Guard against duplicate events in the input collapsing to the same id.
            guard desired.insert(id).inserted else { continue }

            if currentlyScheduled.contains(id) { continue }
            toSchedule.append(.meetingReminder(id: id, event: event, fireDate: fireDate))
        }

        let toCancel = currentlyScheduled.subtracting(desired)
        return Plan(toSchedule: toSchedule, toCancel: toCancel)
    }
}
