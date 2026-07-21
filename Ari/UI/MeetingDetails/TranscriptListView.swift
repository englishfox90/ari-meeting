//
//  TranscriptListView.swift — speaker-labelled, timecode-tappable transcript lines
//  (plan §2.2 MeetingDetails).
//
import AriKit
import AriViewModels
import SwiftUI

struct TranscriptListView: View {
    let transcript: [Transcript]
    let displayName: (SpeakerID?) -> String?
    let onSeek: (Double) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if transcript.isEmpty {
            VStack(spacing: MarginaliaSpacing.xs.value) {
                Text("No transcript yet")
                    .marginaliaTextStyle(.body, in: scheme)
                Text("This meeting has no transcribed speech.")
                    .marginaliaTextStyle(.callout, in: scheme)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(MarginaliaSpacing.xl.value)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                    ForEach(transcript) { line in
                        TranscriptSegmentRow(line: line, speakerName: displayName(line.speakerId), onSeek: onSeek)
                    }
                }
                .padding(MarginaliaSpacing.md.value)
            }
        }
    }
}
