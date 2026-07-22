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
    /// The speaker's real voiceprint signature, or `nil` when none is enrolled — the glyph then
    /// renders its honest placeholder (No-Fake-State), never a fabricated ring.
    var speakerSignature: [Float]?
    let onSeek: (Double) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                if let audioStartTime = line.audioStartTime {
                    // Bracketed monospace timecode, tappable to seek — accent is a sanctioned
                    // "link" use of the Signal color (MarginaliaRules.accentAllowedOn).
                    Button {
                        onSeek(audioStartTime)
                    } label: {
                        Text("[\(MarginaliaTimecode.mmss(audioStartTime))]")
                            .marginaliaTextStyle(.timecode, in: scheme, ink: .accent)
                    }
                    .buttonStyle(.plain)
                }
                if let speakerName {
                    // The speaker's voiceprint ring as the avatar — same voice → same ring. A
                    // `nil` signature renders the glyph's honest placeholder dot, never a fake
                    // ring (No-Fake-State).
                    HStack(spacing: MarginaliaSpacing.xs.value) {
                        VoiceprintGlyph(signature: speakerSignature, size: 18)
                        Text(speakerName)
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    }
                } else {
                    // Honest: never a fabricated "Speaker 1" — diarization simply hasn't resolved
                    // this segment (No-Fake-State).
                    Text("No speaker")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
                Spacer(minLength: 0)
            }
            Text(line.transcript)
                .marginaliaTextStyle(.body, in: scheme)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
