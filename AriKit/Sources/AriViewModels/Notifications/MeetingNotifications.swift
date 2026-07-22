//
//  MeetingNotifications.swift — the @MainActor coordinator that turns real app state (synced
//  calendar events, saved-meeting summaries, stored preferences) into posted notifications, via
//  the `NotificationScheduling` seam. The Swift port of the frozen Rust `NotificationManager`,
//  scoped to the two cases we actually ship: calendar reminders (F5) and summary-ready alerts.
//
//  Owned by `AppEnvironment` (composition root) and mount-independent — the reminder reconcile
//  loop and the summary-ready hook both run regardless of which screen is visible. All settings
//  reads are tolerant: an unset/failed read falls back to the documented default (No-Fake-State
//  at the data layer), never blanks the feature silently.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class MeetingNotifications: NotificationAuthorizing {
    /// The last-known OS authorization, surfaced to the Settings screen's honest banner. `@Observable`
    /// so a change (e.g. after the user grants permission) re-renders the banner.
    public private(set) var authorization: NotificationAuthorization = .notDetermined

    /// A summary that took at least this long to generate is considered "long" — the user has
    /// likely tabbed away, so a completion notification is worth posting. Shorter generations are
    /// silent (the user is almost certainly still watching the screen). Matches the product ask
    /// ("long summaries completed (over 30s)").
    public static let summaryDurationThreshold: Duration = .seconds(30)

    /// How far ahead reminders are scheduled with the OS. Must be ≥ any lead time and comfortably
    /// larger than the calendar sync window so an event never sits un-remindered between reconciles;
    /// events beyond it get their reminder on the reconcile after they enter the horizon.
    private static let scheduleHorizon: TimeInterval = 14 * 24 * 60 * 60

    private let scheduler: any NotificationScheduling
    private let database: AppDatabase
    /// Injectable clock so tests are deterministic; production passes real `Date()`.
    private let now: @Sendable () -> Date

    public init(
        scheduler: any NotificationScheduling,
        database: AppDatabase,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scheduler = scheduler
        self.database = database
        self.now = now
    }

    // MARK: - Authorization (NotificationAuthorizing)

    @discardableResult
    public func refreshAuthorization() async -> NotificationAuthorization {
        let status = await scheduler.authorizationStatus()
        authorization = status
        return status
    }

    public func authorizationStatus() async -> NotificationAuthorization {
        await refreshAuthorization()
    }

    @discardableResult
    public func requestAuthorization() async -> NotificationAuthorization {
        let status = await scheduler.requestAuthorization()
        authorization = status
        return status
    }

    // MARK: - Calendar reminders (F5)

    /// Reconcile the OS's pending meeting reminders against the calendar + current settings. Safe to
    /// call repeatedly (idempotent): the planner only schedules genuinely-new future reminders and
    /// cancels ones no longer warranted. When the feature is off or delivery isn't permitted, it
    /// clears any leftover reminders so a disabled toggle can't leave stale ones armed.
    public func reconcileReminders() async {
        let settings = database.settings
        let enabled = await (try? settings.bool(forKey: .notificationsMeetingReminders))
            ?? SettingsViewModel.Defaults.meetingReminders
        let pending = await scheduler.pendingReminderIdentifiers()

        let status = await refreshAuthorization()
        guard enabled, status.allowsDelivery else {
            if !pending.isEmpty {
                await scheduler.cancel(identifiers: pending)
            }
            return
        }

        let leadMinutes = await storedLeadMinutes(settings)
        let lead = Duration.seconds(max(0, leadMinutes) * 60)

        let currentDate = now()
        let window = currentDate ... currentDate.addingTimeInterval(Self.scheduleHorizon)
        let events = (try? await database.calendarEvents.events(startingIn: window)) ?? []

        let plan = MeetingReminderPlanner.plan(
            events: events,
            leadTime: lead,
            now: currentDate,
            currentlyScheduled: pending
        )
        if !plan.toCancel.isEmpty {
            await scheduler.cancel(identifiers: plan.toCancel)
        }
        for request in plan.toSchedule {
            await scheduler.post(request)
        }
    }

    /// The stored lead time in minutes, parsed from the string KV value, falling back to the
    /// default on an unset or unparseable value.
    private func storedLeadMinutes(_ settings: SettingsRepository) async -> Int {
        let raw = await (try? settings.string(forKey: .notificationsReminderLeadMinutes)) ?? nil
        return raw.flatMap(Int.init) ?? SettingsViewModel.Defaults.reminderLeadMinutes
    }

    // MARK: - Summary-ready

    /// Post a summary-ready notification IFF the generation was "long" (≥ threshold), the setting is
    /// on, and delivery is permitted. Called by `MeetingProcessingCoordinator` right after a summary
    /// finishes generating; `elapsed` is that generation's real wall-clock duration.
    public func summaryGenerated(meetingId: MeetingID, elapsed: Duration) async {
        guard elapsed >= Self.summaryDurationThreshold else { return }
        let enabled = await (try? database.settings.bool(forKey: .notificationsSummaryReady))
            ?? SettingsViewModel.Defaults.summaryReadyNotification
        guard enabled else { return }
        guard await refreshAuthorization().allowsDelivery else { return }

        let title: String?
        if let meeting = try? await database.meetings.find(meetingId) {
            title = meeting.title
        } else {
            title = nil
        }
        await scheduler.post(.summaryReady(meetingId: meetingId, meetingTitle: title))
    }
}
