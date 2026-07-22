//
//  SystemNotificationScheduler.swift — the concrete `NotificationScheduling` over
//  `UNUserNotificationCenter` (macOS local notifications). Lives in the app target so `AriViewModels`
//  never imports the UserNotifications framework and stays unit-testable with a fake.
//
//  Stateless wrapper (the notification center is a process-global, thread-safe singleton), so it is
//  unconditionally `Sendable` — no stored mutable state to protect. Notification categories +
//  actions (the "Start Recording" button) are registered once at construction.
//
import AriKit
import AriViewModels
import Foundation
import UserNotifications

final class SystemNotificationScheduler: NotificationScheduling {
    /// Computed (never stored) so the type holds NO non-Sendable state and is unconditionally
    /// `Sendable` — `UNUserNotificationCenter.current()` is the process-global, thread-safe
    /// singleton, so re-resolving it per call is free and always the same instance.
    private var center: UNUserNotificationCenter { .current() }

    init() {
        registerCategories()
    }

    /// Register the two categories. The meeting-reminder category carries a "Start Recording"
    /// foreground action; both categories also handle the default tap (routed by the delegate).
    private func registerCategories() {
        let startAction = UNNotificationAction(
            identifier: NotificationAction.startRecording,
            title: "Start Recording",
            options: [.foreground]
        )
        let reminderCategory = UNNotificationCategory(
            identifier: NotificationCategory.meetingReminder.rawValue,
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )
        let summaryCategory = UNNotificationCategory(
            identifier: NotificationCategory.summaryReady.rawValue,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([reminderCategory, summaryCategory])
    }

    func authorizationStatus() async -> NotificationAuthorization {
        let settings = await center.notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    func requestAuthorization() async -> NotificationAuthorization {
        // Idempotent per the OS: once decided, this shows no second prompt and just returns the
        // settled status. A thrown error (rare) collapses to reading the current status.
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    func pendingReminderIdentifiers() async -> Set<String> {
        let requests = await center.pendingNotificationRequests()
        let prefix = NotificationCategory.meetingReminder.rawValue + "."
        return Set(requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
    }

    func cancel(identifiers: Set<String>) async {
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
    }

    func post(_ request: NotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = request.category.rawValue
        content.userInfo = request.userInfo

        let trigger: UNNotificationTrigger?
        switch request.trigger {
        case .immediate:
            trigger = nil
        case let .date(date):
            // A calendar trigger fires at the real wall-clock instant (survives sleep), unlike a
            // time-interval trigger which counts down. A fire time in the past (rare race with
            // reconcile) is clamped to ~now so it delivers immediately rather than never.
            let fireDate = max(date, Date().addingTimeInterval(1))
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        let unRequest = UNNotificationRequest(
            identifier: request.id, content: content, trigger: trigger
        )
        try? await center.add(unRequest)
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .authorized
        @unknown default: .notDetermined
        }
    }
}
