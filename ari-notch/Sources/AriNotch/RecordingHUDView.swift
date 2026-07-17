//
//  RecordingHUDView.swift
//  ari-notch
//
//  WS-C — the UC2 Recording HUD. A SwiftUI view bound to the @Observable
//  `NotchModel`, mounted inside the DynamicNotch panel (see main.swift). It
//  renders, per tech-requirements §5 WS-C acceptance:
//
//    • elapsed mm:ss, ticked LOCALLY between authoritative `recording_state`
//      updates and re-synced to the authoritative `elapsed_seconds` whenever a
//      new state arrives (No-Fake-State: never invents time before the first
//      state — the timer only shows while `isRecording`);
//    • a REC dot in Arivo Amber (#E8A020) — the Signal-Rule accent, kept ≤8% of
//      the surface (dot + the primary Stop affordance ONLY);
//    • a live audio-level bar driven by the model's latest `audio_level` (0..1);
//    • an OPTIONAL transcript line (only when config `show_transcript_line` is on
//      AND a line exists — otherwise nothing is drawn, no placeholder text);
//    • Pause/Resume and Stop buttons that emit the outbound action via an
//      injected `NotchActionEmitter` (never touches stdout directly, so the view
//      stays unit-testable with a mock emitter).
//
//  DESIGN: amber lands ONLY on the REC dot + Stop button. Labels, timer,
//  meeting name, transcript, and the audio bar use warm muted ink — never amber.
//  Flat, dark-mode aware (the notch background is near-black).
//

import SwiftUI

// MARK: - Emitter abstraction (keeps the view testable)

/// Sink for outbound actions produced by HUD controls. The real implementation
/// (in main.swift) serializes `NotchOutbound.action(...)` to one stdout NDJSON
/// line; tests inject a capturing mock.
protocol NotchActionEmitter {
    func emit(_ action: NotchAction)
}

// Brand tokens (amber / ink / mutedInk) + the glass/amber/circle button styles
// + the live audio meter now live in `NotchStyle.swift` (one Swift source of
// truth). See the README drift table.

// MARK: - Recording HUD

struct RecordingHUDView: View {
    /// Authoritative UI state, folded from inbound messages on the main actor.
    var model: NotchModel
    /// Outbound sink for control taps (Pause/Resume/Stop).
    let emitter: any NotchActionEmitter

    // Local elapsed clock. `baseElapsed` is the last AUTHORITATIVE value; we
    // advance from `syncedAt` locally so the timer ticks smoothly between
    // `recording_state` updates, then re-sync whenever a new one arrives.
    @State private var baseElapsed: UInt64 = 0
    @State private var syncedAt: Date = .init()
    // Brief "Stopping…" confirmation after a Stop tap.
    @State private var stopConfirming: Bool = false
    // Reveals the open-app affordance when the pointer is over the island.
    @State private var isHovering: Bool = false
    // Drives the gentle REC-dot pulse (only while actively recording).
    @State private var pulsing: Bool = false

    private var isActivelyRecording: Bool { model.isRecording && !model.isPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            AudioMeterView(level: model.audioLevel)
            transcriptLine
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 260, alignment: .leading)
        .background(Color.black.opacity(0.001)) // hit-testable, lets notch bg show
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
        .onAppear {
            resync()
            pulsing = isActivelyRecording
        }
        .onChange(of: model.elapsedSeconds) { resync() }
        .onChange(of: model.isRecording) {
            resync()
            // Clear any stale "Stopping…" so a brand-new session never reopens
            // showing the previous session's stop confirmation.
            stopConfirming = false
            pulsing = isActivelyRecording
        }
        .onChange(of: model.isPaused) {
            resync()
            pulsing = isActivelyRecording
        }
    }

    // MARK: Rows

    private var topRow: some View {
        HStack(spacing: 8) {
            recIndicator
            // Elapsed ticks locally; re-render every second via TimelineView.
            TimelineView(.periodic(from: syncedAt, by: 1.0)) { context in
                Text(Self.formatElapsed(displayedSeconds(at: context.date)))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(NotchPalette.ink)
                    .monospacedDigit()
            }
            if let name = model.meetingName, !name.isEmpty {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(NotchPalette.mutedInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            openAppButton
        }
    }

    /// REC dot — the amber Signal-Rule accent. Muted (not amber) while paused,
    /// since the recording is not actively capturing. Gently pulses while active.
    private var recIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isPaused ? NotchPalette.mutedInk : NotchPalette.amber)
                .frame(width: 9, height: 9)
                .opacity(pulsing ? 0.45 : 1.0)
                .animation(
                    isActivelyRecording
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
            Text(model.isPaused ? "PAUSED" : "REC")
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.bold)
                .foregroundStyle(NotchPalette.mutedInk) // label is muted ink, never amber
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.isPaused ? "Recording paused" : "Recording")
    }

    /// Circular "open Ari" affordance, revealed on hover. Emits the already-wired
    /// `open_app` action (shows + focuses the main app window). Utility control —
    /// never amber.
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

    /// Optional transcript line: only when config allows AND a line exists.
    /// Renders nothing otherwise — no placeholder text (No-Fake-State).
    @ViewBuilder
    private var transcriptLine: some View {
        if model.showTranscriptLine, let line = model.latestTranscript, !line.text.isEmpty {
            HStack(spacing: 4) {
                if let speaker = line.speaker, !speaker.isEmpty {
                    Text(speaker)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(NotchPalette.mutedInk)
                }
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(NotchPalette.ink.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: handlePauseResume) {
                Label(
                    model.isPaused ? "Resume" : "Pause",
                    systemImage: model.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(GlassCapsuleButtonStyle(disabledLook: stopConfirming))
            .disabled(stopConfirming)

            Spacer(minLength: 0)

            // Primary Stop — the second (and only other) amber accent surface.
            Button(action: handleStop) {
                Label(
                    stopConfirming ? "Stopping…" : "Stop",
                    systemImage: "stop.fill"
                )
            }
            .buttonStyle(AccentCapsuleButtonStyle(dimmed: stopConfirming))
            .disabled(stopConfirming)
            .accessibilityLabel("Stop recording")
        }
    }

    // MARK: - Actions (extracted so tests can drive them directly)

    /// Emit pause when recording, resume when paused. No local state mutation so
    /// authoritative `recording_state` remains the source of truth for the toggle.
    func handlePauseResume() {
        emitter.emit(model.isPaused ? .resume : .pause)
    }

    /// Emit stop and show a brief confirming state until the next authoritative
    /// state (or shutdown) supersedes it.
    func handleStop() {
        emitter.emit(.stop)
        stopConfirming = true
    }

    /// Bring the main Ari window forward. Emits the already-wired `open_app`
    /// action (no route → just show + focus the app).
    func handleOpenApp() {
        emitter.emit(.openApp(route: nil))
    }

    // MARK: - Local elapsed clock

    /// Re-anchor the local clock to the authoritative value.
    private func resync() {
        baseElapsed = model.elapsedSeconds
        syncedAt = Date()
    }

    /// Elapsed seconds to display at `now`: the authoritative base, advanced
    /// locally only while actively recording (frozen while paused / stopped).
    /// Never invents time when not recording.
    func displayedSeconds(at now: Date) -> UInt64 {
        guard model.isRecording, !model.isPaused else { return baseElapsed }
        let delta = now.timeIntervalSince(syncedAt)
        guard delta > 0 else { return baseElapsed }
        return baseElapsed + UInt64(delta)
    }

    /// Format whole seconds as mm:ss (minutes are NOT wrapped at 60 → 3600 = "60:00").
    static func formatElapsed(_ seconds: UInt64) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
