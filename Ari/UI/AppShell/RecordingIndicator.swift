//
//  RecordingIndicator.swift — the persistent live-capture pill (plan §4.4, slice R7).
//
//  A recording-red TINTED glass capsule floating over the detail pane while a session is
//  active and the user is anywhere OTHER than the recording page — the live-capture Signal
//  (recording red is exclusive to live capture; the page itself carries the Signal when open,
//  so `RootSplitView` hides this there — never two red glass elements on one screen).
//
//  Everything shown is real state: the elapsed clock derives from the session's true
//  `startedAt` via `TimelineView` (never an accumulated counter), and `stopping` reads
//  "Finishing…" honestly. Labels are `.canvas` on-fill ink per the on-fill convention.
//
import AriKit
import AriViewModels
import SwiftUI

struct RecordingIndicator: View {
    let session: RecordingSession
    let onReturn: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch session.phase {
        case let .recording(startedAt):
            pill(startedAt: startedAt, label: "Recording")
        case .stopping:
            pill(startedAt: nil, label: "Finishing…")
        case .starting:
            pill(startedAt: nil, label: "Starting…")
        case .idle, .consentPrompt, .saved, .failed:
            EmptyView()
        }
    }

    private func pill(startedAt: Date?, label: String) -> some View {
        Button(action: onReturn) {
            HStack(spacing: MarginaliaSpacing.xs.value) {
                Circle()
                    .fill(Color.marginalia(.canvas, in: scheme))
                    .frame(width: 6, height: 6)
                Text(label)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .canvas)
                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(MarginaliaTimecode.mmss(context.date.timeIntervalSince(startedAt)))
                            .marginaliaTextStyle(.timecode, in: scheme, ink: .canvas)
                    }
                }
                if !session.pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(session.pendingTitle)
                        .marginaliaTextStyle(.caption, in: scheme, ink: .canvas)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)
            .padding(.vertical, MarginaliaSpacing.xs.value)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.marginalia(.recordingRed, in: scheme)).interactive(),
            in: Capsule()
        )
        .accessibilityLabel("Recording in progress. Return to the live meeting.")
    }
}
