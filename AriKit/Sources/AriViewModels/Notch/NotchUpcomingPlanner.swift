//
//  NotchUpcomingPlanner.swift — the pure decision core for the upcoming-meeting island alert
//  (docs/plans/notch-panel-absorption.md Amendment A §A.2).
//
//  Framework-free, static, side-effect-free port of the Rust `due_events` (`frontend/src-tauri/
//  src/notch/scheduler.rs:97-150`) — the SAME fire/dismiss rules, operating directly on
//  `AriKit.CalendarEvent` (`has_meeting` ≡ `meetingId != nil`; no separate `SchedEvent`
//  projection is needed since the app's own model already carries everything `due_events` reads).
//
//  Deliberate divergence from the Rust incumbent (documented, not a bug carried forward):
//  ALL-DAY EVENTS ARE SKIPPED here. Rust's `due_events`/`row_to_sched` never filters all-day
//  events (`scheduler.rs:157-177`) — a latent bug that could fire a midnight prompt. Every sibling
//  Swift surface already skips them (`MeetingReminderPlanner.swift`, `CalendarBriefViewModel.swift`)
//  — this is the one place the Swift port deliberately BEATS rather than matches the incumbent.
//
import AriKit
import Foundation

public enum NotchUpcomingPlanner {
    /// Rust `FIRE_TOLERANCE` (scheduler.rs:49): must exceed half the tick interval so at least one
    /// tick lands inside the window, while staying small enough that a late app-start never
    /// resurrects a long-past lead.
    public static let fireTolerance: TimeInterval = 45

    /// Rust `LINGER_AFTER_START` (scheduler.rs:62). Deliberately equal to
    /// `CalendarBriefViewModel.lateJoinMinutes` — the Rust comment pinned the same equivalence to
    /// the panel's `LATE_JOIN_MINUTES`.
    public static let lingerAfterStart: TimeInterval = 30 * 60

    /// Rust `RANGE_SLACK_MINUTES` (scheduler.rs:53) — used by the live scheduler's DB range query
    /// (`NotchUpcomingScheduler`), not by this pure core.
    public static let rangeSlack: TimeInterval = 2 * 60

    /// One admitted `(event, lead)` pair — the typed mirror of Rust's `(String, i64)` fire tuple.
    public struct Fire: Hashable, Sendable {
        public var eventId: CalendarEventID
        public var leadMinutes: Int

        public init(eventId: CalendarEventID, leadMinutes: Int) {
            self.eventId = eventId
            self.leadMinutes = leadMinutes
        }
    }

    /// The decisions produced by one tick — the mirror of Rust's `Reminders` (scheduler.rs:80-84).
    public struct Decision: Equatable, Sendable {
        public var fire: [Fire]
        public var dismiss: [CalendarEventID]

        public init(fire: [Fire] = [], dismiss: [CalendarEventID] = []) {
            self.fire = fire
            self.dismiss = dismiss
        }
    }

    /// Pure mirror of `due_events` (scheduler.rs:97-150).
    ///
    /// Fire rule: for an event that has NOT started, does NOT already have a linked meeting, and
    /// is NOT all-day (Swift-only addition, see file header), fire `(id, lead)` when
    /// `|now - (start - lead)| <= fireTolerance` and it has not already fired.
    ///
    /// Dismiss rule: an event that was fired at least once is dismissed (once) when its start has
    /// passed by more than `lingerAfterStart` OR it gained a linked meeting. An event that was
    /// previously fired but is absent from `events` (cancelled / rolled out of range) is also
    /// dismissed. Already-dismissed events are never re-emitted.
    public static func dueEvents(
        now: Date,
        events: [CalendarEvent],
        leadsMinutes: [Int],
        fired: Set<Fire>,
        dismissed: Set<CalendarEventID>
    ) -> Decision {
        var fire: [Fire] = []
        var dismiss: [CalendarEventID] = []

        // Set of event ids present in the current range this tick.
        let present = Set(events.map(\.id))

        for event in events {
            let hasMeeting = event.meetingId != nil
            let alreadyStarted = now >= event.startTime
            // The prompt lingers past the scheduled start; it only expires once the grace window
            // has also elapsed (so a late user can still hit record).
            let lingerExpired = now >= event.startTime.addingTimeInterval(lingerAfterStart)

            // ---- Dismissals for present events ----
            let wasFired = fired.contains { $0.eventId == event.id }
            if wasFired, !dismissed.contains(event.id), lingerExpired || hasMeeting {
                dismiss.append(event.id)
                // A dismissed event should not also fire this tick.
                continue
            }

            // ---- Fires ----
            // Swift-only divergence: all-day events never fire (file header).
            guard !event.isAllDay else { continue }
            guard !hasMeeting, !alreadyStarted else { continue }
            for lead in leadsMinutes {
                let fireTime = event.startTime.addingTimeInterval(-Double(lead) * 60)
                let delta = abs(now.timeIntervalSince(fireTime))
                let candidate = Fire(eventId: event.id, leadMinutes: lead)
                if delta <= fireTolerance, !fired.contains(candidate) {
                    fire.append(candidate)
                }
            }
        }

        // ---- Dismiss events that were fired but have vanished from the range ----
        for entry in fired where !present.contains(entry.eventId) && !dismissed.contains(entry.eventId) {
            // Avoid pushing the same id twice (multiple leads may have fired).
            if !dismiss.contains(entry.eventId) {
                dismiss.append(entry.eventId)
            }
        }

        return Decision(fire: fire, dismiss: dismiss)
    }
}
