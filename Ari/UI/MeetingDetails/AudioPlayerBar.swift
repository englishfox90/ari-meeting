//
//  AudioPlayerBar.swift — transport + timecode readout (plan §2.2 MeetingDetails, §5).
//
//  Rendered only when `audio == .available` — an absent bar is the honest response to a
//  `nil` audio reference (plan §5); `.missing` renders its own honest reason text instead
//  (see `MeetingDetailView`), never a dead scrubber.
//
//  A floating Liquid Glass capsule (chrome/action layer — liquid-glass-adoption.md v2),
//  not an opaque band: `MeetingDetailView` places it in a bottom `safeAreaInset` so the
//  transcript scrolls beneath it and the glass keeps it legible. Neutral `.regular` glass
//  — the transport is passive chrome, not the Signal.
//
import AriKit
import AriViewModels
import SwiftUI

struct AudioPlayerBar: View {
    let controller: AudioPlayerController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Button {
                controller.isPlaying ? controller.pause() : controller.play()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))

            Text(MarginaliaTimecode.mmss(controller.currentTime))
                .marginaliaTextStyle(.timecode, in: scheme)
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.vertical, MarginaliaSpacing.xs.value)
        .glassEffect(.regular, in: Capsule())
    }
}
