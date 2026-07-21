//
//  AudioPlayerBar.swift — transport + timecode readout (plan §2.2 MeetingDetails, §5).
//
//  Rendered only when `audio == .available` — an absent bar is the honest response to a
//  `nil` audio reference (plan §5); `.missing` renders its own honest reason text instead
//  (see `MeetingDetailView`), never a dead scrubber.
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

            Text(Self.timecode(controller.currentTime))
                .marginaliaTextStyle(.timecode, in: scheme)
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.vertical, MarginaliaSpacing.sm.value)
        .background(Color.marginalia(.elevated, in: scheme))
    }

    private static func timecode(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
