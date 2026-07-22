//
//  ReminderRefreshScheduler.swift — the periodic reconcile loop that keeps the OS's scheduled
//  meeting reminders in sync with the calendar (parity with `CalendarSyncScheduler`): a short
//  initial delay, then every 15 min, ask `MeetingNotifications` to reconcile. Owned by
//  `AppEnvironment` so its `Task` lives (and is cancelled) with the app, not any one view.
//
//  Settings changes (toggling reminders, changing the lead time) reconcile immediately via the
//  Settings view model's `onNotificationSettingsChanged` closure — this loop is the safety net that
//  catches calendar syncs and the passage of time (events entering the schedule horizon).
//
//  `Sendable` by construction: its one stored property is an immutable `Task`, mirroring
//  `CalendarSyncScheduler`.
//
import AriViewModels
import Foundation

final class ReminderRefreshScheduler: Sendable {
    private static let initialDelay: Duration = .seconds(3)
    private static let interval: Duration = .seconds(15 * 60)

    private let task: Task<Void, Never>

    init(notifications: MeetingNotifications) {
        task = Task {
            try? await Task.sleep(for: Self.initialDelay)
            // First pass also requests OS authorization if a default-ON feature was never prompted,
            // so the shipped-on toggles aren't silently dead on a fresh install.
            await notifications.prepareForLaunch()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                await notifications.reconcileReminders()
            }
        }
    }

    deinit {
        task.cancel()
    }
}
