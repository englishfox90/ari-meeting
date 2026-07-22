//
//  SpeakerCountPromptSheet.swift — the app-level speaker-count prompt (docs/plans/
//  swift-meeting-generation-flow.md, Track 2 "UI integration" #1).
//
//  Presented whenever `MeetingProcessingCoordinator.phase == .needsSpeakerCount`: the
//  post-recording pipeline resolved a recording but no calendar/participant hint, so it paused to
//  ask. Mirrors the count-entry half of `IdentifySpeakersSheet` (two explicit modes, H2 — never
//  one ambiguous field): "Exactly N" maps to `.clampedExact`; "Not sure / at most N" always maps
//  to `.clampedUpperBound`, never silently upgraded to a forced-precision `.exact`.
//
//  Plain closures only (`onSubmit`/`onSkip`) — this view knows nothing about
//  `MeetingProcessingCoordinator`; the caller (`RootSplitView`) wires both to the coordinator's
//  intents. No-Fake-State: "Identify" stays disabled until a genuine positive integer is entered
//  — never a defaulted/invented count.
//
import AriKit
import SwiftUI

struct SpeakerCountPromptSheet: View {
    /// The user entered a count and asked to identify speakers with it.
    let onSubmit: (SpeakerCountHint) -> Void
    /// The user chose to skip speaker identification for this meeting.
    let onSkip: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private enum CountMode: String, CaseIterable, Identifiable, Hashable, Sendable {
        case exact, uncertain
        var id: String { rawValue }
        var title: String {
            switch self {
            case .exact: "Exactly"
            case .uncertain: "Not sure"
            }
        }
    }

    @State private var countMode: CountMode = .uncertain
    @State private var countText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Text("How many people were in this meeting?")
                    .marginaliaTextStyle(.title2, in: scheme)
                Text("A rough speaker count helps identify who's speaking in the recording. You can skip this and identify speakers later from the meeting.")
                    .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            }

            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                MarginaliaSegmentedControl(
                    selection: $countMode,
                    segments: CountMode.allCases.map { MarginaliaSegment(value: $0, title: $0.title) },
                    scheme: scheme
                )
                MarginaliaTextField(text: $countText, prompt: "Number of speakers", scheme: scheme)
                    .frame(width: 200)
            }

            HStack(spacing: MarginaliaSpacing.md.value) {
                Button("Skip") {
                    onSkip()
                    dismiss()
                }
                .buttonStyle(.marginalia(.quiet, .large, in: scheme))

                Button("Identify") {
                    guard let hint = resolvedHint else { return }
                    onSubmit(hint)
                    dismiss()
                }
                .buttonStyle(.marginalia(.primary, .large, in: scheme))
                .disabled(resolvedHint == nil)
            }
        }
        .padding(MarginaliaSpacing.xl.value)
        .frame(minWidth: 420)
    }

    /// `nil` until a genuine positive integer is entered — the "Identify" action stays disabled
    /// on an honestly-absent count rather than falling back to a fabricated default.
    private var resolvedHint: SpeakerCountHint? {
        guard let n = Int(countText), n > 0 else { return nil }
        switch countMode {
        case .exact: return .clampedExact(n)
        case .uncertain: return .clampedUpperBound(n)
        }
    }
}
