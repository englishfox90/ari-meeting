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
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let categoryId = response.notification.request.content.categoryIdentifier

        switch categoryId {
        case NotificationCategory.meetingReminder.rawValue:
            guard let raw = userInfo[NotificationUserInfoKey.eventId] as? String else { return }
            // Both the explicit "Start Recording" action AND a plain tap on the reminder start the
            // recording (product decision: the reminder's whole purpose is to capture the meeting).
            switch response.actionIdentifier {
            case NotificationAction.startRecording, UNNotificationDefaultActionIdentifier:
                onStartRecording?(CalendarEventID(raw))
            default:
                break
            }

        case NotificationCategory.summaryReady.rawValue:
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let raw = userInfo[NotificationUserInfoKey.meetingId] as? String else { return }
            onOpenMeeting?(MeetingID(raw))

        default:
            break
        }
    }
}
