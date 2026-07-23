//
//  NotificationScheduling.swift — the local-notification seam (the Swift port of the frozen Rust
//  `notifications/` subsystem, scoped to the two ported cases: calendar reminders + summary-ready).
//
//  This is the ONLY abstraction the testable layer (`MeetingNotifications`, `SettingsViewModel`)
//  talks to. The concrete `UNUserNotificationCenter` implementation lives in the app target
//  (`Ari/App/Notifications/SystemNotificationScheduler.swift`) so this package never imports the
//  `UserNotifications` framework and stays unit-testable with an in-memory fake.
//
//  No-Fake-State: `NotificationAuthorization` mirrors the OS's real `UNAuthorizationStatus` — the
//  UI surfaces the honest permission state (e.g. "denied → open System Settings"), never a
//  fabricated "on".
//
import AriKit
import Foundation

/// The real OS authorization state for local notifications (a lossless mirror of
/// `UNAuthorizationStatus`, defined here so the package doesn't import UserNotifications).
public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional

    /// Whether the OS will actually surface a delivered notification. `.provisional` delivers
    /// quietly (Notification Center only) but still counts as deliverable.
    public var allowsDelivery: Bool {
        self == .authorized || self == .provisional
    }
}

/// Which kind of notification a request is — drives the registered category (and therefore which
/// actions appear) on the concrete side, and routing on receipt.
public enum NotificationCategory: String, Sendable, CaseIterable {
    case meetingReminder = "MEETING_REMINDER"
    case summaryReady = "SUMMARY_READY"
    case recordingStarted = "RECORDING_STARTED"
}

/// Stable action identifiers used by both the concrete scheduler (to register the button) and the
/// delegate (to route a tap). Kept here so the two sides can never drift.
public enum NotificationAction {
    /// The "Start Recording" button on a meeting-reminder notification.
    public static let startRecording = "START_RECORDING"
}

/// Keys used inside `NotificationRequest.userInfo` — shared so the poster and the receiver agree.
public enum NotificationUserInfoKey {
    public static let eventId = "eventId"
    public static let meetingId = "meetingId"
}

/// When a request should fire.
public enum NotificationTrigger: Sendable, Equatable {
    /// Deliver as soon as it's posted (summary-ready).
    case immediate
    /// Deliver at a wall-clock instant (a scheduled meeting reminder).
    case date(Date)
}

/// A framework-agnostic notification to post. The concrete scheduler maps this onto a
/// `UNNotificationRequest`; tests assert against it directly.
public struct NotificationRequest: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var category: NotificationCategory
    public var userInfo: [String: String]
    public var trigger: NotificationTrigger

    public init(
        id: String,
        title: String,
        body: String,
        category: NotificationCategory,
        userInfo: [String: String],
        trigger: NotificationTrigger
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.category = category
        self.userInfo = userInfo
        self.trigger = trigger
    }
}

/// The seam. `Sendable` so it can cross into the reconcile loop's detached task; every method is
/// `async` so the concrete side can hop to `UNUserNotificationCenter`'s async API without exposing
/// a completion-handler shape here.
public protocol NotificationScheduling: Sendable {
    /// The current OS authorization, without prompting.
    func authorizationStatus() async -> NotificationAuthorization
    /// Prompt for authorization if undetermined, then return the resulting status. Idempotent —
    /// re-calling once decided just returns the settled status (the OS shows no second prompt).
    func requestAuthorization() async -> NotificationAuthorization
    /// Identifiers of currently-PENDING (not-yet-fired) meeting-reminder requests only — the input
    /// to reconciliation. Excludes summary-ready (those are immediate, never pending) and any
    /// non-reminder request, so reconcile never cancels something it doesn't own.
    func pendingReminderIdentifiers() async -> Set<String>
    /// Remove pending requests by identifier (a no-op for identifiers that already fired/were removed).
    func cancel(identifiers: Set<String>) async
    /// Schedule/deliver a request. A duplicate identifier replaces the existing pending request
    /// (matching `UNUserNotificationCenter.add`'s replace-by-identifier semantics).
    func post(_ request: NotificationRequest) async
}

/// The narrow authorization surface `SettingsViewModel` depends on — a subset of the coordinator's
/// job, so the Settings screen can read/prompt permission and drive the honest banner without
/// reaching for the whole `MeetingNotifications` type or the raw scheduler.
public protocol NotificationAuthorizing: Sendable {
    func authorizationStatus() async -> NotificationAuthorization
    func requestAuthorization() async -> NotificationAuthorization
}

// MARK: - Copy factories (the one place notification wording lives)

public extension NotificationRequest {
    /// A "meeting starts soon" reminder for `event`, firing at `fireDate` (already computed as
    /// `startTime − leadTime` by the planner). Carries the event id so the action handler can prime
    /// a recording for exactly this event.
    static func meetingReminder(id: String, event: CalendarEvent, fireDate: Date) -> NotificationRequest {
        let leadMinutes = max(0, Int((event.startTime.timeIntervalSince(fireDate) / 60).rounded()))
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Upcoming meeting"
            : event.title
        let body = switch leadMinutes {
        case 0:
            "Starting now — tap Start Recording to capture it."
        case 1:
            "Starts in 1 minute — tap Start Recording to capture it."
        default:
            "Starts in \(leadMinutes) minutes — tap Start Recording to capture it."
        }
        return NotificationRequest(
            id: id,
            title: title,
            body: body,
            category: .meetingReminder,
            userInfo: [NotificationUserInfoKey.eventId: event.id.rawValue],
            trigger: .date(fireDate)
        )
    }

    /// The stable identifier for a summary-ready notification (one per meeting; re-posting replaces).
    static func summaryReadyIdentifier(meetingId: MeetingID) -> String {
        "\(NotificationCategory.summaryReady.rawValue).\(meetingId.rawValue)"
    }

    /// A "your summary is ready" notification. Delivered immediately; carries the meeting id so a
    /// tap opens that meeting.
    static func summaryReady(meetingId: MeetingID, meetingTitle: String?) -> NotificationRequest {
        let trimmed = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = if let trimmed, !trimmed.isEmpty {
            "Your summary for “\(trimmed)” is ready."
        } else {
            "Your meeting summary is ready."
        }
        return NotificationRequest(
            id: summaryReadyIdentifier(meetingId: meetingId),
            title: "Summary ready",
            body: body,
            category: .summaryReady,
            userInfo: [NotificationUserInfoKey.meetingId: meetingId.rawValue],
            trigger: .immediate
        )
    }

    /// The stable identifier for the recording-started alert. A single fixed id (one live recording
    /// at a time, mirroring the session's re-entrancy guard) so a re-post can only replace, never
    /// stack.
    static let recordingStartedIdentifier = "\(NotificationCategory.recordingStarted.rawValue).active"

    /// A "recording started" courtesy alert, delivered immediately. Especially relevant with the
    /// consent prompt off by default: the non-blocking reminder to let participants know they're
    /// being recorded. Carries no meeting id — it fires at capture start, before the meeting row is
    /// necessarily openable — so a tap just foregrounds the app (default routing).
    static func recordingStarted(meetingTitle: String?) -> NotificationRequest {
        let trimmed = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = if let trimmed, !trimmed.isEmpty {
            "Recording “\(trimmed)” — let everyone on the call know."
        } else {
            "Recording started — let everyone on the call know."
        }
        return NotificationRequest(
            id: recordingStartedIdentifier,
            title: "Recording",
            body: body,
            category: .recordingStarted,
            userInfo: [:],
            trigger: .immediate
        )
    }
}
