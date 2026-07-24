//
//  SpeakerAssignmentRow.swift — one resolved-cluster row in the "Identify speakers" sheet
//  (docs/plans/arikit-diarization.md §5 D9b, §6; narrowed in
//  docs/plans/speaker-retag-and-calendar-candidates.md §2, step 4).
//
//  Renders honestly by tier (No-Fake-State, invariant I2): `.identified` shows the real resolved
//  name with a reassign affordance; `.assignable` offers Confirm/Not them when a suggestion
//  exists, else an Assign-person picker — nothing is written until Confirm (invariant I1).
//
//  Narrowed to the fields this row ACTUALLY renders (never `.score`) — a fresh run's
//  `MatchTier` (`.autoConfirm` → `.identified`, `.suggest`/`.anonymous` → `.assignable`) and a
//  reconstruction's `isAssigned` (`true` → `.identified`, `false` → `.assignable`) both map into
//  this same small enum without either path fabricating a match score (No-Fake-State).
//
import AriKit
import SwiftUI

/// Render-only tier for one speaker row — never carries a fabricated score (see file header).
enum SpeakerRenderTier {
    case identified
    case assignable
}

struct SpeakerAssignmentRow: View {
    let speakerId: SpeakerID
    let tier: SpeakerRenderTier
    let speechSecs: Double
    /// The speaker's resolved display name for `.identified` rows — sourced from
    /// `MeetingDetailViewModel.speakerNames` after a post-run reload. `nil` when the tier isn't
    /// `.identified`, or the reload hasn't caught up yet (rendered honestly, never guessed).
    let resolvedName: String?
    /// The top-ranked assign-picker suggestion for `.assignable` rows, if any.
    let suggestion: (personId: PersonID, name: String, score: Float)?
    /// D9b review fix: the underlying tier is a static snapshot from the run/reconstruction and
    /// never updates after a confirm. When the sheet has confirmed this row in the current
    /// session, it passes the confirmed name here, which overrides the tier-derived label/actions
    /// with the same success-badge + Reassign presentation `.identified` uses — never
    /// re-rendering a just-confirmed speaker as Unidentified/re-confirmable.
    let confirmedOverrideName: String?
    let onConfirmSuggestion: () -> Void
    let onNotThem: () -> Void
    let onAssign: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                tierLabel
                Text("\(MarginaliaTimecode.mmss(speechSecs)) speaking")
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
        if let confirmedOverrideName {
            MarginaliaBadge(confirmedOverrideName, style: .success, symbol: "checkmark.seal", scheme: scheme)
        } else {
            tierDerivedLabel
        }
    }

    @ViewBuilder
    private var tierDerivedLabel: some View {
        switch tier {
        case .identified:
            if let resolvedName {
                MarginaliaBadge(resolvedName, style: .success, symbol: "checkmark.seal", scheme: scheme)
            } else {
                // Matched a previously-confirmed voiceprint, but the name hasn't resolved from
                // the store yet — honest, not a fabricated placeholder (No-Fake-State).
                Text("Identified speaker")
                    .marginaliaTextStyle(.body, in: scheme)
            }
        case .assignable:
            if let suggestion {
                Text("Looks like \(suggestion.name) (\(Int((suggestion.score * 100).rounded()))%)")
                    .marginaliaTextStyle(.body, in: scheme)
            } else {
                Text("Unidentified speaker")
                    .marginaliaTextStyle(.body, in: scheme)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if confirmedOverrideName != nil {
            Button("Reassign", action: onAssign)
                .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        } else {
            tierDerivedActions
        }
    }

    @ViewBuilder
    private var tierDerivedActions: some View {
        switch tier {
        case .identified:
            Button("Reassign", action: onAssign)
                .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        case .assignable:
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
        }
    }
}
