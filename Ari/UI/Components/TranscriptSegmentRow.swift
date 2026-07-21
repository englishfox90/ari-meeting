//
//  TranscriptSegmentRow.swift — shared transcript-line row: speaker name, seek timecode,
//  transcript text (plan §2.1 Wave 2; lifted verbatim from the former private
//  `TranscriptLineView` in `TranscriptListView.swift`).
//
import AriKit
import SwiftUI

struct TranscriptSegmentRow: View {
    let line: Transcript
    let speakerName: String?
    let onSeek: (Double) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                if let speakerName {
                    Text(speakerName)
                        .marginaliaTextStyle(.subheadline, in: scheme)
                }
                if let audioStartTime = line.audioStartTime {
                    Button(MarginaliaTimecode.mmss(audioStartTime)) {
                        onSeek(audioStartTime)
                    }
                    .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                    .font(MarginaliaTextStyle.timecode.font)
                }
            }
            Text(line.transcript)
                .marginaliaTextStyle(.body, in: scheme)
        }
    }
}
