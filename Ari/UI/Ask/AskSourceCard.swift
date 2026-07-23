//
//  AskSourceCard.swift — the source-card content rendered inside `AskSourcePopover`
//  (docs/plans/ari-ask-ui.md §7/§8): S-number, title, meeting date (if present), a clamped
//  match-context excerpt, person tags (ONLY when `speakers` is non-empty — No-Fake-State,
//  `speakers` is always `[]` today per plan §0), and an "Open meeting →" affordance.
//
import AriKit
import SwiftUI

struct AskSourceCard: View {
    let index: Int
    let source: RecallSource
    let onOpenMeeting: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    /// Person tags are capped (plan §8 "max 4") — never a fabricated "+N more" count, just a
    /// silent truncation, matching the plan's literal instruction.
    private static let maxPersonTags = 4
    private static let maxExcerptLength = 320

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            HStack(spacing: MarginaliaSpacing.xs.value) {
                Text("S\(index)")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .accent)
                Text(source.title)
                    .marginaliaTextStyle(.headline, in: scheme, ink: .inkHeading)
            }

            if let meetingDate = source.meetingDate, !meetingDate.isEmpty {
                Text(meetingDate)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }

            Text(clampedExcerpt)
                .marginaliaTextStyle(.body, in: scheme)
                .fixedSize(horizontal: false, vertical: true)

            if !source.speakers.isEmpty {
                personTags
            }

            Button {
                onOpenMeeting(source.meetingId)
            } label: {
                Label("Open meeting", systemImage: "arrow.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: 320, alignment: .leading)
    }

    private var clampedExcerpt: String {
        let excerpt = source.matchContext
        guard excerpt.count > Self.maxExcerptLength else { return excerpt }
        return String(excerpt.prefix(Self.maxExcerptLength)) + "…"
    }

    private var personTags: some View {
        MarginaliaFlowLayout(spacing: MarginaliaSpacing.xs.value, lineSpacing: MarginaliaSpacing.xs.value) {
            ForEach(source.speakers.prefix(Self.maxPersonTags), id: \.self) { name in
                MarginaliaBadge(name, style: .neutral, symbol: "person", scheme: scheme)
            }
        }
    }
}
