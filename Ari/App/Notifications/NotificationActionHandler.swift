//
//  NotificationActionHandler.swift — the `UNUserNotificationCenterDelegate` that routes a tapped
//  notification back into the app: a meeting reminder starts recording for that event; a
//  summary-ready tap opens that meeting. Both routes are plain @MainActor closures the composition
//  root (`AppEnvironment`) wires up.
//
//  Retained strongly by `AppEnvironment` (the notification center holds its delegate weakly), so
//  install it only once the environment owns it.
//
import AriKit
import AriViewModels
import Foundation
import UserNotifications

@MainActor
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    /// Start (immediately, per the 2026-07-22 product decision) a recording primed with this event.
    var onStartRecording: ((CalendarEventID) -> Void)?
    /// Open the meeting whose summary just became ready.
    var onOpenMeeting: ((MeetingID) -> Void)?

    /// Point the notification center at this handler. Called by `AppEnvironment` after it retains us.
    func install(into center: UNUserNotificationCenter = .current()) {
        center.delegate = self
    }

    /// Present reminders/summary alerts even while Ari is foregrounded (a banner + sound), so the
    /// user isn't silently un-notified just because the window is open.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // The system calls this off the main actor with non-Sendable arguments, so the method is
    // `nonisolated`: we pull the Sendable fields (plain strings) off `response` on the calling
    // thread and hand only those to the main-actor `handle(...)` — never crossing `response` itself
    // over the isolation boundary.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let categoryId = response.notification.request.content.categoryIdentifier
        let actionId = response.actionIdentifier
        let eventId = userInfo[NotificationUserInfoKey.eventId] as? String
        let meetingId = userInfo[NotificationUserInfoKey.meetingId] as? String

        await handle(categoryId: categoryId, actionId: actionId, eventId: eventId, meetingId: meetingId)
    }

    private func handle(categoryId: String, actionId: String, eventId: String?, meetingId: String?) {
        switch categoryId {
        case NotificationCategory.meetingReminder.rawValue:
            guard let eventId else { return }
            // Both the explicit "Start Recording" action AND a plain tap on the reminder start the
            // recording (product decision: the reminder's whole purpose is to capture the meeting).
            switch actionId {
            case NotificationAction.startRecording, UNNotificationDefaultActionIdentifier:
                onStartRecording?(CalendarEventID(eventId))
            default:
                break
            }

        case NotificationCategory.summaryReady.rawValue:
            guard actionId == UNNotificationDefaultActionIdentifier, let meetingId else { return }
            onOpenMeeting?(MeetingID(meetingId))

        default:
            break
        }
    }
}
