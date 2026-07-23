//
//  NotchUpcomingScheduler.swift — the live `NotchUpcomingProviding` conformer that drives the
//  island's upcoming-meeting alert (docs/plans/notch-panel-absorption.md Amendment A §A.3).
//
//  A 30 s tick (Rust `TICK_INTERVAL`, scheduler.rs:39) reads the stored reminder lead, queries
//  the calendar-event range that lead implies, runs the pure `NotchUpcomingPlanner.dueEvents`, and
//  applies the resulting fire/dismiss decisions to a single-slot `activeAlert`. Everything here is
//  `@MainActor` — no locks, no `@unchecked Sendable`; the loop is one `Task` owned by this class
//  and cancelled in `deinit` (the `ReminderRefreshScheduler` pattern,
//  `Ari/App/Notifications/ReminderRefreshScheduler.swift`).
//
//  `fired`/`dismissed` are IN-MEMORY ONLY, scoped to this scheduler's lifetime (Rust parity,
//  scheduler.rs:192-193) — never persisted. `NotchOverlayCoordinator` tears the scheduler down
//  when the overlay is disabled, so a toggle off→on can re-fire a prompt still inside its 45 s
//  tolerance window; that ≤45 s edge is accepted (plan §A.3).
//
import AriKit
import Foundation
import Observation
import os

@MainActor
@Observable
public final class NotchUpcomingScheduler: NotchUpcomingProviding {
    private static let log = Logger(subsystem: "com.arivo.ari.AriViewModels", category: "notch.upcoming")

    /// One admitted upcoming alert's presentation data. A later fire replaces an earlier one —
    /// Rust pushed each fire and the sidecar showed the last, same net behavior (single slot).
    public struct ActiveAlert: Equatable, Sendable {
        public var eventId: CalendarEventID
        public var title: String
        public var startDate: Date
        public var attendeeCount: Int

        public init(eventId: CalendarEventID, title: String, startDate: Date, attendeeCount: Int) {
            self.eventId = eventId
            self.title = title
            self.startDate = startDate
            self.attendeeCount = attendeeCount
        }
    }

    public private(set) var activeAlert: ActiveAlert?

    /// `NotchUpcomingProviding`. `alreadyRecording` is COMPUTED LIVE from `session.phase` — never
    /// a stale at-fire-time snapshot (Rust's was, scheduler.rs:257-261) — true for exactly the
    /// phases where `startRecordingFromReminder` would refuse to start
    /// (`AppEnvironment.swift:368-373`), so the Record button's disabled state is honest and
    /// re-enables the instant a recording ends.
    public var current: NotchUpcomingMeeting? {
        guard let activeAlert else { return nil }
        return NotchUpcomingMeeting(
            eventId: activeAlert.eventId,
            title: activeAlert.title,
            startDate: activeAlert.startDate,
            attendeeCount: activeAlert.attendeeCount,
            alreadyRecording: isAlreadyRecordingPhase(session.phase)
        )
    }

    private let database: AppDatabase
    private let session: RecordingSession
    private let now: @Sendable () -> Date
    private let tickInterval: Duration
    /// `@ObservationIgnored` (not part of the view's tracked state) + `nonisolated(unsafe)`:
    /// `deinit` isn't main-actor isolated, so cancellation on teardown needs off-actor access to
    /// this property. Safe: `Task<Void, Never>` is `Sendable`, and `Task.cancel()` merely flips an
    /// atomic flag — callable from any context. Every other access to `task` stays on the main
    /// actor (assigned only inside `init`). Same deinit-teardown caveat
    /// `NotchOverlayCoordinator`/`NotchPanelController` document for their own
    /// `NotificationCenter` observer removal.
    @ObservationIgnored
    private nonisolated(unsafe) var task: Task<Void, Never>?

    /// Per-`(event, lead)` fire de-dup and per-event dismiss state — in-memory only (file header).
    private var fired: Set<NotchUpcomingPlanner.Fire> = []
    private var dismissed: Set<CalendarEventID> = []

    public init(
        database: AppDatabase,
        session: RecordingSession,
        now: @escaping @Sendable () -> Date = Date.init,
        tickInterval: Duration = .seconds(30),
        initialDelay: Duration = .seconds(3)
    ) {
        self.database = database
        self.session = session
        self.now = now
        self.tickInterval = tickInterval
        task = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                await self?.evaluateNow()
                guard let tickInterval = self?.tickInterval else { return }
                try? await Task.sleep(for: tickInterval)
            }
        }
    }

    /// One synchronous evaluation against `now()` — the tick body, minus sleeping. Exposed for
    /// deterministic tests (plan §A.6 suite 14).
    public func evaluateNow() async {
        let now = now()
        let leadMinutes = await readLeadMinutes()
        let rangeStart = now.addingTimeInterval(-NotchUpcomingPlanner.lingerAfterStart)
        let rangeEnd = now.addingTimeInterval(
            Double(leadMinutes) * 60 + NotchUpcomingPlanner.rangeSlack
        )
        let events: [CalendarEvent]
        do {
            events = try await database.calendarEvents.events(startingIn: rangeStart...rangeEnd)
        } catch {
            Self.log.warning("failed to read calendar events for upcoming-alert evaluation: \(error)")
            events = []
        }

        let decision = NotchUpcomingPlanner.dueEvents(
            now: now,
            events: events,
            leadsMinutes: [leadMinutes],
            fired: fired,
            dismissed: dismissed
        )

        guard !decision.fire.isEmpty || !decision.dismiss.isEmpty else { return }

        let byId = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for entry in decision.fire {
            guard let event = byId[entry.eventId] else { continue }
            activeAlert = ActiveAlert(
                eventId: event.id,
                title: event.title,
                startDate: event.startTime,
                attendeeCount: event.attendees.count
            )
            fired.insert(entry)
        }

        for eventId in decision.dismiss {
            dismissed.insert(eventId)
            if activeAlert?.eventId == eventId {
                activeAlert = nil
            }
        }
    }

    /// True for exactly the phases `startRecordingFromReminder` refuses to re-enter
    /// (`AppEnvironment.swift:368-373`).
    private func isAlreadyRecordingPhase(_ phase: RecordingSession.Phase) -> Bool {
        switch phase {
        case .consentPrompt, .starting, .recording, .stopping:
            true
        case .idle, .saved, .failed:
            false
        }
    }

    /// The stored reminder lead (`SettingKey.notificationsReminderLeadMinutes`), falling back to
    /// `SettingsViewModel.Defaults.reminderLeadMinutes` on an absent/unparseable row — the same
    /// documented default the Settings screen itself applies, so island and banner timing stay in
    /// lockstep (plan §A.4, R5).
    private func readLeadMinutes() async -> Int {
        do {
            if let stored = try await database.settings.int(forKey: .notificationsReminderLeadMinutes) {
                return stored
            }
        } catch {
            Self.log.warning("failed to read reminder lead minutes; falling back to default: \(error)")
        }
        return SettingsViewModel.Defaults.reminderLeadMinutes
    }

    deinit {
        task?.cancel()
    }
}
