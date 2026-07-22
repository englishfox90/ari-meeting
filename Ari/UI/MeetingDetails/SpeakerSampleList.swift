//
//  SpeakerSampleList.swift — speaker identification evidence: the real transcribed lines a
//  speaker said, each with a play button that jumps the meeting audio to that moment (port of
//  the frozen Rust/React `frontend/src/components/MeetingDetails/SpeakerSampleList.tsx`).
//
//  The active clip is the only place amber (the ≤8% Signal accent) appears here — a sanctioned
//  "citations"/"links" use (`MarginaliaRules.accentAllowedOn`), and only while that exact clip
//  is actually playing. No-Fake-State: when there are no samples, this renders nothing — never
//  a placeholder implying evidence exists.
//
import AriKit
import AriViewModels
import SwiftUI

struct SpeakerSampleList: View {
    /// Representative lines the speaker said (already selected/ordered by `SpeakerSamples`).
    let samples: [SpeakerSamples.SpeakerSample]
    /// Whether a playable recording exists. When false, play is disabled honestly.
    let audioAvailable: Bool
    /// Whether the shared meeting player is currently playing.
    let isPlaying: Bool
    /// Play the clip from its start; the second argument is the clip's known end (`nil` if
    /// unknown), so playback stops at the clip boundary instead of bleeding into later audio.
    let onPlayClip: (Double, Double?) -> Void
    /// Cap how many lines to render (`nil` = all provided) — mirrors the TS `limit` prop.
    var limit: Int?

    @Environment(\.colorScheme) private var scheme
    /// Tracks the last-tapped sample so its row can be highlighted while it plays. Cleared once
    /// `isPlaying` flips false, mirroring `SpeakerSampleList.tsx`'s `activeClipId` effect.
    @State private var activeClipId: TranscriptID?

    private var shown: [SpeakerSamples.SpeakerSample] {
        guard let limit else { return samples }
        return Array(samples.prefix(limit))
    }

    var body: some View {
        // No-Fake-State: zero samples means zero evidence to show — render nothing, never a
        // fabricated "no lines yet" placeholder in place of real evidence.
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                ForEach(shown) { sample in
                    row(for: sample)
                }
            }
            .onChange(of: isPlaying) { _, playing in
                if !playing { activeClipId = nil }
            }
        }
    }

    @ViewBuilder
    private func row(for sample: SpeakerSamples.SpeakerSample) -> some View {
        let active = activeClipId == sample.id && isPlaying

        HStack(alignment: .top, spacing: MarginaliaSpacing.sm.value) {
            Button {
                activeClipId = sample.id
                onPlayClip(sample.startSeconds, sample.endSeconds)
            } label: {
                Image(systemName: active ? "pause.circle" : "play.circle")
                    .foregroundStyle(active ? Color.marginalia(.accent, in: scheme) : Color.marginalia(.inkSecondary, in: scheme))
            }
            .buttonStyle(.plain)
            .disabled(!audioAvailable)
            .help(audioAvailable ? "Play from \(MarginaliaTimecode.mmss(sample.startSeconds))" : "No recording audio available")

            VStack(alignment: .leading, spacing: 2) {
                Text("[\(MarginaliaTimecode.mmss(sample.startSeconds))]")
                    .marginaliaTextStyle(.timecode, in: scheme, ink: active ? .accent : .inkSecondary)
                Text(sample.text)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    .lineLimit(limit == nil ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
