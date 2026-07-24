//
//  NotchUpcomingMeetingView.swift — WS-G, ported from
//  ari-notch/Sources/AriNotch/UpcomingMeetingView.swift (docs/plans/notch-panel-absorption.md
//  §2, §4, §10 step 4).
//
//  Renders whenever `model.upcomingMeeting` is non-nil — driven live by `NotchUpcomingScheduler`
//  (the `NotchUpcomingProviding` conformer); this view compiles, unit-tests, and previews against
//  `nil`/injected fixtures via that same protocol seam:
//    • the meeting TITLE (primary ink, truncating);
//    • a countdown to start, derived from `model.remainingSeconds(at:)` (never negative —
//      clamps to "Starting now" at 0, No-Fake-State);
//    • the ATTENDEE count ("2 attendees") in muted ink — ONLY when `attendeeCount > 0` (no fake
//      "0 attendees");
//    • a primary RECORD button in `.accent` (the Signal-Rule accent for this view) that calls
//      `model.recordTapped()`. When `alreadyRecording` is true, Record is replaced by a muted,
//      non-interactive "Recording..." state (can't double-record);
//    • a small secondary DISMISS control that calls `model.dismissUpcoming()` — LOCAL-only
//      (plan §2: emits nothing; the model records the dismissed event id itself).
//
//  DESIGN: `.accent` lands ONLY on the primary Record button. Title = `.inkBody`; countdown,
//  attendees, and the "Recording..." label = `.inkSecondary`.
//
import AriViewModels
import SwiftUI

struct NotchUpcomingMeetingView: View {
    var model: NotchOverlayModel

    @Environment(\.colorScheme) private var scheme
    // Reveals the open-app affordance when the pointer is over the island.
    @State private var isHovering = false

    var body: some View {
        if let meeting = model.upcomingMeeting {
            content(meeting)
        }
    }

    private func content(_ meeting: NotchUpcomingMeeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow(meeting)
            countdownRow(meeting)
            controls(meeting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 260, alignment: .leading)
        .background(Color.black.opacity(0.001)) // hit-testable, lets the island bg show
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
    }

    // MARK: Rows

    private func titleRow(_ meeting: NotchUpcomingMeeting) -> some View {
        HStack(spacing: 8) {
            Text("UPCOMING")
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme)) // eyebrow, never the accent
            Text(meeting.title)
                .font(.system(.body))
                .fontWeight(.semibold)
                .foregroundStyle(Color.marginalia(.inkBody, in: scheme))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            openAppButton
        }
    }

    /// Countdown (re-renders every second via `TimelineView`, derived ONLY from
    /// `model.remainingSeconds(at:)`) + optional attendee count — both muted ink.
    private func countdownRow(_ meeting: NotchUpcomingMeeting) -> some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(NotchOverlayModel.formatCountdown(model.remainingSeconds(at: context.date)))
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                    .monospacedDigit()
            }
            // Attendee count ONLY when > 0 — no fake "0 attendees" (No-Fake-State).
            if meeting.attendeeCount > 0 {
                Text(NotchOverlayModel.formatAttendees(meeting.attendeeCount))
                    .font(.caption)
                    .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Circular "open Ari" affordance, revealed on hover. Utility control — never the accent.
    @ViewBuilder
    private var openAppButton: some View {
        if isHovering {
            Button(action: model.openAppTapped) {
                Image(systemName: "arrow.up.forward")
            }
            .buttonStyle(CircleIconButtonStyle(scheme: scheme))
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .accessibilityLabel("Open Ari")
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ meeting: NotchUpcomingMeeting) -> some View {
        HStack(spacing: 8) {
            // Secondary, muted Dismiss — collapses the alert locally via the model, emits
            // nothing (plan §2).
            Button("Dismiss", action: model.dismissUpcoming)
                .buttonStyle(NotchGlassCapsuleButtonStyle(scheme: scheme))
                .accessibilityLabel("Dismiss upcoming meeting")

            Spacer(minLength: 0)

            if meeting.alreadyRecording {
                // Already recording this event — can't double-record. Muted, non-interactive
                // state instead of the accent.
                Text("Recording…")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                    .accessibilityLabel("Already recording")
            } else {
                // Primary Record — the single `.accent` Signal-Rule surface for this view.
                Button(action: model.recordTapped) {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .buttonStyle(NotchAccentCapsuleButtonStyle(scheme: scheme))
                .accessibilityLabel("Record this meeting")
            }
        }
    }
}
