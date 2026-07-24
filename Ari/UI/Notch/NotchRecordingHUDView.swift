//
//  NotchRecordingHUDView.swift — WS-C, ported from ari-notch/Sources/AriNotch/RecordingHUDView.swift
//  (docs/plans/notch-panel-absorption.md §2, §10 step 2).
//
//  A SwiftUI view bound to `NotchOverlayModel` (the real `RecordingSession`, via Observation —
//  not a periodic wire snapshot). Renders:
//    • elapsed mm:ss, derived ONLY from the real `.recording(startedAt:)` timestamp
//      (`model.displayedSeconds(at:)`) — never advances outside `.recording` (No-Fake-State);
//    • a REC dot in `.recordingRed` — the Signal-Rule accent, kept <=8% of the surface (dot +
//      the Stop button ONLY);
//    • a live audio-level bar driven by the model's REAL `audioLevel`;
//    • an OPTIONAL transcript line: the last PERSISTED segment's text, or nothing — no
//      placeholder (No-Fake-State);
//    • a Stop button that calls `model.stopTapped()` directly (the model holds no reference to
//      `CaptureService` — plan §8).
//
//  Pause/Resume DROPPED (plan §2, §9): no pause phase exists on `RecordingSession`. The
//  sidecar's local `stopConfirming` @State is REPLACED by the real `model.isStopping` (the
//  `.stopping` phase) — an improvement, not a divergence.
//
import AriViewModels
import SwiftUI

struct NotchRecordingHUDView: View {
    var model: NotchOverlayModel

    @Environment(\.colorScheme) private var scheme

    // Reveals the open-app affordance when the pointer is over the island.
    @State private var isHovering = false
    // Drives the gentle REC-dot pulse (only while actively recording, never while stopping).
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            AudioMeterView(level: Double(model.audioLevel), scheme: scheme)
            transcriptLine
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 260, alignment: .leading)
        .background(Color.black.opacity(0.001)) // hit-testable, lets the island bg show
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
        .onAppear { pulsing = model.isRecording }
        .onChange(of: model.isRecording) { pulsing = model.isRecording }
        .onChange(of: model.isStopping) { pulsing = model.isRecording }
    }

    // MARK: Rows

    private var topRow: some View {
        HStack(spacing: 8) {
            recIndicator
            // Elapsed re-renders every second via TimelineView; the value itself derives ONLY
            // from the real `.recording(startedAt:)` timestamp (never a local clock to resync).
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                Text(NotchOverlayModel.formatElapsed(model.displayedSeconds(at: context.date)))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.marginalia(.inkBody, in: scheme))
                    .monospacedDigit()
            }
            if let title = model.meetingTitle {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            openAppButton
        }
    }

    /// REC dot — the `.recordingRed` Signal-Rule accent. Muted (not red) and non-pulsing while
    /// stopping, since capture is no longer actively live — the drain is real and finite, not a
    /// pulse implying ongoing capture.
    private var recIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(
                    model.isStopping
                        ? Color.marginalia(.inkSecondary, in: scheme)
                        : Color.marginalia(.recordingRed, in: scheme)
                )
                .frame(width: 9, height: 9)
                .opacity(pulsing ? 0.45 : 1.0)
                .animation(
                    model.isRecording && !model.isStopping
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
            Text(model.isStopping ? "STOPPING" : "REC")
                .font(.system(.caption2, design: .rounded))
                .fontWeight(.bold)
                // Label is muted ink, never the accent — the dot alone carries the signal.
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.isStopping ? "Recording stopping" : "Recording")
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

    /// Optional transcript line: only when a real persisted segment exists. Renders nothing
    /// otherwise — no placeholder text (No-Fake-State).
    @ViewBuilder
    private var transcriptLine: some View {
        if let text = model.latestSegmentText, !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.marginalia(.inkBody, in: scheme).opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            // The single PRIMARY (capture) action — the second (and only other) accent surface:
            // real `.stopping` phase renders "Stopping..." honestly, never a local flag.
            Button(action: model.stopTapped) {
                Label(
                    model.isStopping ? "Stopping…" : "Stop",
                    systemImage: "stop.fill"
                )
            }
            .buttonStyle(NotchRecordingCapsuleButtonStyle(scheme: scheme, dimmed: model.isStopping))
            .disabled(model.isStopping)
            .accessibilityLabel("Stop recording")
        }
    }
}
