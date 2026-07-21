//
//  ListenBackPanel.swift — the "Listen Back" transport: play/pause, a draggable Liquid-Glass
//  scrubber, and a current/duration readout, presented as one floating glass capsule (the
//  macOS 26 / Apple Music transport idiom; glass is the chrome/action layer per
//  docs/plans/liquid-glass-adoption.md).
//
//  The scrubber and total-duration readout stay inert until the controller resolves a real
//  duration (`> 0`) — never a fabricated total or a dead-but-draggable track (No-Fake-State).
//
import AriKit
import SwiftUI

struct ListenBackPanel: View {
    let controller: AudioPlayerController
    @Environment(\.colorScheme) private var scheme

    private var hasDuration: Bool {
        controller.duration > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("Listen back")
                .marginaliaTextStyle(.caption, in: scheme)

            GlassEffectContainer(spacing: MarginaliaSpacing.md.value) {
                HStack(spacing: MarginaliaSpacing.md.value) {
                    Button {
                        controller.isPlaying ? controller.pause() : controller.play()
                    } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.marginalia(.accent, in: scheme))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())

                    GlassScrubber(
                        currentTime: controller.currentTime,
                        duration: controller.duration,
                        onScrub: { controller.seek(toSeconds: $0) }
                    )

                    Text(readout)
                        .marginaliaTextStyle(.timecode, in: scheme)
                        .layoutPriority(1)
                }
                .padding(.horizontal, MarginaliaSpacing.md.value)
                .padding(.vertical, MarginaliaSpacing.sm.value)
                .glassEffect(.regular, in: Capsule())
            }
        }
        .padding(MarginaliaSpacing.md.value)
    }

    private var readout: String {
        let current = MarginaliaTimecode.mmss(controller.currentTime)
        guard hasDuration else { return current }
        return "\(current) / \(MarginaliaTimecode.mmss(controller.duration))"
    }
}

/// A draggable progress track with a Liquid-Glass knob. Inert (no knob, no fill) until a real
/// duration resolves — the honest state for an unresolved total (No-Fake-State).
private struct GlassScrubber: View {
    let currentTime: Double
    let duration: Double
    let onScrub: (Double) -> Void
    @Environment(\.colorScheme) private var scheme

    private let knobDiameter: CGFloat = 20
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
            let knobX = min(max(fraction * width - knobDiameter / 2, 0), width - knobDiameter)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.marginalia(.hairline, in: scheme))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.marginalia(.accent, in: scheme))
                    .frame(width: max(fraction * width, 0), height: trackHeight)
                if duration > 0 {
                    Circle()
                        .fill(Color.marginalia(.surface, in: scheme))
                        .frame(width: knobDiameter, height: knobDiameter)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .offset(x: knobX)
                }
            }
            .frame(height: knobDiameter)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        onScrub(min(max(value.location.x / width, 0), 1) * duration)
                    }
            )
        }
        .frame(height: knobDiameter)
    }
}
