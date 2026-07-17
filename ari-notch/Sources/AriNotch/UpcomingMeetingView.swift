//
//  UpcomingMeetingView.swift
//  ari-notch
//
//  WS-G — the UC1 Upcoming-meeting alert. A SwiftUI view bound to the
//  @Observable `NotchModel`'s upcoming-meeting state, mounted inside the
//  DynamicNotch panel (see main.swift) whenever `model.upcomingMeeting` is set.
//  It renders, per tech-requirements §5 WS-G acceptance:
//
//    • the meeting TITLE (primary ink, truncating);
//    • a LOCAL countdown to start, ticked locally from `starts_in_seconds`
//      (never negative — clamps to "Starting now" at 0, No-Fake-State) and
//      re-synced to the authoritative `starts_in_seconds` whenever a new
//      `upcoming_meeting` arrives;
//    • the ATTENDEE count ("2 attendees") in muted ink — but ONLY when
//      attendee_count > 0 (no fake "0 attendees");
//    • a primary RECORD button in Arivo Amber (the Signal-Rule accent for this
//      view, ≤8%) that emits `NotchAction.recordEvent(event_id:)` via the
//      injected `NotchActionEmitter`. When `already_recording` is true the
//      Record affordance is replaced by a muted, non-interactive "Recording…"
//      state (can't double-record);
//    • a small secondary DISMISS control that collapses the view LOCALLY.
//
//  DISMISS is local-only. The wire protocol (Protocol.swift / protocol.rs)
//  defines NO sidecar→Rust dismiss action — `dismiss_upcoming` flows the other
//  way (Rust→sidecar). So tapping Dismiss emits NOTHING; it just hides the alert
//  by recording the dismissed event_id locally. (If a future requirement needs
//  Rust to learn about a user dismiss, add a wire message on the Rust side first
//  — do not invent one here.)
//
//  DESIGN: amber lands ONLY on the primary Record button — the single accent
//  surface for this view. Title = ink; countdown, attendees, and the Recording…
//  label = muted ink. Flat, dark-mode aware (the notch background is near-black).
//

import SwiftUI

// Brand tokens (amber / ink / mutedInk) + the shared button styles now live in
// `NotchStyle.swift` (one Swift source of truth). See the README drift table.

// MARK: - Upcoming-meeting alert

struct UpcomingMeetingView: View {
    /// Authoritative UI state, folded from inbound messages on the main actor.
    var model: NotchModel
    /// Outbound sink for the Record tap.
    let emitter: any NotchActionEmitter

    // Local countdown clock. `baseStartsIn` is the last AUTHORITATIVE
    // `starts_in_seconds`; we count DOWN from `syncedAt` locally so the timer
    // ticks smoothly between `upcoming_meeting` updates, then re-sync whenever a
    // new one arrives (keyed on event_id + starts_in_seconds).
    @State private var baseStartsIn: UInt64 = 0
    @State private var syncedAt: Date = .init()
    // Event that the user dismissed locally; hides the alert until a DIFFERENT
    // event arrives. Dismiss emits no wire message (see file header).
    @State private var dismissedEventId: String?
    // Reveals the open-app affordance when the pointer is over the island.
    @State private var isHovering: Bool = false

    var body: some View {
        // Auto-collapse: nothing renders when there is no upcoming meeting, or
        // when the current one was locally dismissed.
        if let meeting = model.upcomingMeeting, meeting.eventId != dismissedEventId {
            content(meeting)
        }
    }

    private func content(_ meeting: UpcomingMeeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow(meeting)
            countdownRow(meeting)
            controls(meeting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 260, alignment: .leading)
        .background(Color.black.opacity(0.001)) // hit-testable, lets notch bg show
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
        .onAppear(perform: resync)
        .onChange(of: meeting.eventId) { resync() }
        .onChange(of: meeting.startsInSeconds) { resync() }
    }

    // MARK: Rows

    private func titleRow(_ meeting: UpcomingMeeting) -> some View {
        HStack(spacing: 8) {
            Text("UPCOMING")
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(NotchPalette.mutedInk) // eyebrow is muted ink, never amber
            Text(meeting.title)
                .font(.system(.body))
                .fontWeight(.semibold)
                .foregroundStyle(NotchPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            openAppButton
        }
    }

    /// Countdown (ticked locally) + optional attendee count — both muted ink.
    private func countdownRow(_ meeting: UpcomingMeeting) -> some View {
        HStack(spacing: 8) {
            // Countdown re-renders every second via TimelineView.
            TimelineView(.periodic(from: syncedAt, by: 1.0)) { context in
                Text(Self.formatCountdown(remainingSeconds(at: context.date)))
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(NotchPalette.mutedInk)
                    .monospacedDigit()
            }
            // Attendee count ONLY when > 0 — no fake "0 attendees" (No-Fake-State).
            if meeting.attendeeCount > 0 {
                Text(Self.formatAttendees(meeting.attendeeCount))
                    .font(.caption)
                    .foregroundStyle(NotchPalette.mutedInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Circular "open Ari" affordance, revealed on hover. Emits the already-wired
    /// `open_app` action. Utility control — never amber.
    @ViewBuilder
    private var openAppButton: some View {
        if isHovering {
            Button(action: handleOpenApp) {
                Image(systemName: "arrow.up.forward")
            }
            .buttonStyle(CircleIconButtonStyle())
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .accessibilityLabel("Open Ari")
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ meeting: UpcomingMeeting) -> some View {
        HStack(spacing: 8) {
            // Secondary, muted Dismiss — collapses the alert locally, emits nothing.
            Button("Dismiss", action: handleDismiss)
                .buttonStyle(GlassCapsuleButtonStyle())
                .accessibilityLabel("Dismiss upcoming meeting")

            Spacer(minLength: 0)

            if meeting.alreadyRecording {
                // Already recording this event — can't double-record. Show a
                // muted, non-interactive state instead of the amber accent.
                Text("Recording…")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(NotchPalette.mutedInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                    .accessibilityLabel("Already recording")
            } else {
                // Primary Record — the single amber Signal-Rule accent surface.
                Button(action: handleRecord) {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .buttonStyle(AccentCapsuleButtonStyle())
                .accessibilityLabel("Record this meeting")
            }
        }
    }

    // MARK: - Actions (extracted so tests can drive them directly)

    /// Emit `record_event` for the current upcoming meeting. No-op if the alert
    /// has already cleared or if we're already recording it (button is absent).
    func handleRecord() {
        guard let meeting = model.upcomingMeeting, !meeting.alreadyRecording else { return }
        emitter.emit(.recordEvent(eventId: meeting.eventId))
    }

    /// Dismiss LOCALLY — record the dismissed event_id so the alert collapses.
    /// Emits nothing (the protocol has no sidecar→Rust dismiss action).
    func handleDismiss() {
        dismissedEventId = model.upcomingMeeting?.eventId
    }

    /// Bring the main Ari window forward. Emits the already-wired `open_app`
    /// action (no route → just show + focus the app).
    func handleOpenApp() {
        emitter.emit(.openApp(route: nil))
    }

    // MARK: - Local countdown clock

    /// Re-anchor the local countdown to the authoritative `starts_in_seconds`.
    private func resync() {
        baseStartsIn = model.upcomingMeeting?.startsInSeconds ?? 0
        syncedAt = Date()
    }

    /// Seconds remaining to display at `now`: the authoritative base counted
    /// down locally, clamped at 0 (never negative — No-Fake-State).
    func remainingSeconds(at now: Date) -> UInt64 {
        let delta = now.timeIntervalSince(syncedAt)
        guard delta > 0 else { return baseStartsIn }
        let elapsed = UInt64(delta)
        return elapsed >= baseStartsIn ? 0 : baseStartsIn - elapsed
    }

    /// Format whole seconds remaining as mm:ss (matching WS-C's elapsed style —
    /// zero-padded minutes, not wrapped at 60), or "Starting now" at zero.
    static func formatCountdown(_ seconds: UInt64) -> String {
        if seconds == 0 { return "Starting now" }
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// "1 attendee" / "N attendees". Never called with 0 (caller gates on > 0).
    static func formatAttendees(_ count: UInt32) -> String {
        count == 1 ? "1 attendee" : "\(count) attendees"
    }
}
