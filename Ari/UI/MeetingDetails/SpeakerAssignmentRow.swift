//
//  SpeakerAssignmentRow.swift — one resolved-cluster row in the "Identify speakers" sheet
//  (docs/plans/arikit-diarization.md §5 D9b, §6).
//
//  Renders honestly by tier (No-Fake-State, invariant I2): `autoConfirm` shows the real
//  resolved name with a reassign affordance; `suggest` offers Confirm/Not them — nothing is
//  written until Confirm (invariant I1); `anonymous` (or a `suggest` row with no candidate to
//  name) offers an Assign-person picker. Never a fabricated name or score.
//
import AriKit
import SwiftUI

struct SpeakerAssignmentRow: View {
    let resolved: DiarizationService.ResolvedSpeaker
    /// The speaker's resolved display name for `.autoConfirm` rows — sourced from
    /// `MeetingDetailViewModel.speakerNames` after a post-run reload. `nil` when the tier isn't
    /// `.autoConfirm`, or the reload hasn't caught up yet (rendered honestly, never guessed).
    let resolvedName: String?
    /// The top-ranked assign-picker suggestion for `.suggest`/`.anonymous` rows, if any.
    let suggestion: (personId: PersonID, name: String, score: Float)?
    let onConfirmSuggestion: () -> Void
    let onNotThem: () -> Void
    let onAssign: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                tierLabel
                Text("\(MarginaliaTimecode.mmss(resolved.speechSecs)) speaking")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            actions
        }
        .padding(.vertical, MarginaliaSpacing.sm.value)
        .padding(.horizontal, MarginaliaSpacing.md.value)
    }

    @ViewBuilder
    private var tierLabel: some View {
        switch resolved.tier {
        case .autoConfirm:
            if let resolvedName {
                MarginaliaBadge(resolvedName, style: .success, symbol: "checkmark.seal", scheme: scheme)
            } else {
                // Matched a previously-confirmed voiceprint, but the name hasn't resolved from
                // the store yet — honest, not a fabricated placeholder (No-Fake-State).
                Text("Identified speaker")
                    .marginaliaTextStyle(.body, in: scheme)
            }
        case .suggest:
            if let suggestion {
                Text("Looks like \(suggestion.name) (\(Int((suggestion.score * 100).rounded()))%)")
                    .marginaliaTextStyle(.body, in: scheme)
            } else {
                Text("Unidentified speaker")
                    .marginaliaTextStyle(.body, in: scheme)
            }
        case .anonymous:
            Text("Unidentified speaker")
                .marginaliaTextStyle(.body, in: scheme)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch resolved.tier {
        case .autoConfirm:
            Button("Reassign", action: onAssign)
                .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        case .suggest:
            if suggestion != nil {
                HStack(spacing: MarginaliaSpacing.xs.value) {
                    Button("Confirm", action: onConfirmSuggestion)
                        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                    Button("Not them", action: onNotThem)
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            } else {
                Button("Assign person…", action: onAssign)
                    .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            }
        case .anonymous:
            Button("Assign person…", action: onAssign)
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
        }
    }
}
