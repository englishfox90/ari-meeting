//
//  NotchOverlayModel.swift — the testable brain for the in-process notch overlay
//  (docs/plans/notch-panel-absorption.md §2, §4, §8).
//
//  Successor of the ari-notch sidecar's `NotchModel` (the wire-fold model) — this reads the app's
//  OWN `RecordingSession` directly via Observation (not NDJSON), so every displayed value derives
//  from real, honest state rather than a periodic wire snapshot:
//    • `presentation` derives from `session.phase` + the upcoming seam (driven live by
//      `NotchUpcomingScheduler`) — never a fabricated flag (`IslandPresentation.derive`).
//    • `displayedSeconds(at:)` derives from the REAL `.recording(startedAt:)` timestamp — no local
//      clock to resync, unlike the sidecar, which only ever had a periodic wire snapshot to
//      interpolate between.
//    • `latestSegmentText` is the last PERSISTED transcript segment or nothing — no placeholder.
//    • `stopTapped()` calls the real `session.stop()`; there is no local "Stopping…" flag — the
//      real `.stopping` phase already renders that honestly (`isStopping`).
//
//  Consent-before-record (plan §8): this model holds no reference to `CaptureService` at all.
//  `recordTapped()` only ever calls the injected `onRecordEvent` closure, which the app wires to
//  `startRecordingFromReminder` — the SAME sanctioned consent path the menu bar and calendar
//  reminders already use.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class NotchOverlayModel {
    private let session: RecordingSession
    private let upcoming: (any NotchUpcomingProviding)?
    private let onOpenApp: @MainActor () -> Void
    private let onRecordEvent: @MainActor (CalendarEventID) -> Void

    /// The upcoming meeting the user dismissed locally (`dismissUpcoming()`) — hides the alert
    /// until a DIFFERENT event arrives from the provider. Dismiss emits nothing; it is purely
    /// local UI state, mirroring the sidecar's own local-only dismiss (never a wire message).
    private var dismissedEventId: CalendarEventID?

    public init(
        session: RecordingSession,
        upcoming: (any NotchUpcomingProviding)? = nil,
        onOpenApp: @escaping @MainActor () -> Void,
        onRecordEvent: @escaping @MainActor (CalendarEventID) -> Void
    ) {
        self.session = session
        self.upcoming = upcoming
        self.onOpenApp = onOpenApp
        self.onRecordEvent = onRecordEvent
    }

    // MARK: - Presentation

    /// The upcoming meeting to show, if any and not locally dismissed.
    private var visibleUpcoming: NotchUpcomingMeeting? {
        guard let meeting = upcoming?.current, meeting.eventId != dismissedEventId else { return nil }
        return meeting
    }

    public var presentation: IslandPresentation {
        IslandPresentation.derive(phase: session.phase, hasUpcoming: visibleUpcoming != nil)
    }

    /// The upcoming meeting `NotchUpcomingMeetingView` (app target) binds to — `nil` when there is
    /// none, or when the current one was locally dismissed.
    public var upcomingMeeting: NotchUpcomingMeeting? { visibleUpcoming }

    // MARK: - Recording HUD bindings

    public var isRecording: Bool {
        if case .recording = session.phase { return true }
        return false
    }

    /// Honest "Stopping…" state — the real drain phase, never a local flag standing in for it.
    public var isStopping: Bool {
        if case .stopping = session.phase { return true }
        return false
    }

    /// The persisted meeting title — mirrors the EXACT trim + "Untitled meeting" fallback
    /// `RecordingSession.performStart()` uses to create the Meeting row, so the HUD never shows a
    /// different title than what was actually saved. `nil` outside recording/stopping — nothing to
    /// show once the title stops being relevant.
    public var meetingTitle: String? {
        guard isRecording || isStopping else { return nil }
        let trimmed = session.pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled meeting" : trimmed
    }

    /// The real live audio level, verbatim — no smoothing/fabrication here (the meter view owns
    /// any visual damping).
    public var audioLevel: Float { session.liveLevel }

    /// The last PERSISTED transcript segment's text, or `nil` — never a placeholder line
    /// (No-Fake-State).
    public var latestSegmentText: String? { session.segments.last?.transcript }

    /// Elapsed seconds to display at `now`, derived ONLY from the real `.recording(startedAt:)`
    /// timestamp. Never advances in any other phase — including `.stopping`, where the drain is
    /// real and finite, not a ticking clock.
    public func displayedSeconds(at now: Date) -> UInt64 {
        guard case let .recording(startedAt) = session.phase else { return 0 }
        let delta = now.timeIntervalSince(startedAt)
        guard delta > 0 else { return 0 }
        return UInt64(delta)
    }

    /// Format whole seconds as mm:ss (minutes are NOT wrapped at 60 → 3600 = "60:00") — ported
    /// verbatim from the sidecar's `RecordingHUDView.formatElapsed`.
    public static func formatElapsed(_ seconds: UInt64) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: - Upcoming-meeting bindings

    /// Seconds remaining until `visibleUpcoming.startDate`, clamped at 0 (never negative —
    /// No-Fake-State). `0` when there is no upcoming meeting to show.
    public func remainingSeconds(at now: Date) -> UInt64 {
        guard let meeting = visibleUpcoming else { return 0 }
        let delta = meeting.startDate.timeIntervalSince(now)
        guard delta > 0 else { return 0 }
        return UInt64(delta)
    }

    /// Format whole seconds remaining as mm:ss (matching `formatElapsed`'s style), or
    /// "Starting now" at zero — ported verbatim from the sidecar's
    /// `UpcomingMeetingView.formatCountdown`.
    public static func formatCountdown(_ seconds: UInt64) -> String {
        if seconds == 0 { return "Starting now" }
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// "1 attendee" / "N attendees" — ported verbatim from the sidecar's
    /// `UpcomingMeetingView.formatAttendees`. Never called with 0 (callers gate on `> 0`).
    public static func formatAttendees(_ count: Int) -> String {
        count == 1 ? "1 attendee" : "\(count) attendees"
    }

    // MARK: - Actions

    /// The island's only capture control this slice (plan §8) — routes straight to the real
    /// `session.stop()`; no local flag stands in for the real `.stopping` phase.
    public func stopTapped() {
        Task { await session.stop() }
    }

    public func openAppTapped() {
        onOpenApp()
    }

    /// Routes through the injected closure ONLY — never touches `CaptureService` directly (plan
    /// §8). No-op when the current upcoming meeting is already being recorded (can't
    /// double-record), mirroring the sidecar's own guard.
    public func recordTapped() {
        guard let meeting = visibleUpcoming, !meeting.alreadyRecording else { return }
        onRecordEvent(meeting.eventId)
    }

    /// Local-only: hides the current upcoming alert until a DIFFERENT event arrives. Emits
    /// nothing and leaves the provider's own state untouched.
    public func dismissUpcoming() {
        dismissedEventId = upcoming?.current?.eventId
    }
}
