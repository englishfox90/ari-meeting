//
//  AskSourceCard.swift — the source-card content rendered inside `AskSourcePopover`
//  (docs/plans/ari-ask-ui.md §7/§8): S-number, title, meeting date (if present), a clamped
//  match-context excerpt, person tags (ONLY when `speakers` is non-empty — No-Fake-State,
//  `speakers` is always `[]` today per plan §0), and an "Open meeting →" affordance.
//
import AriKit
import Foundation
import SwiftUI

struct AskSourceCard: View {
    let index: Int
    let source: RecallSource
    let onOpenMeeting: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    /// Person tags are capped (plan §8 "max 4") — never a fabricated "+N more" count, just a
    /// silent truncation, matching the plan's literal instruction.
    private static let maxPersonTags = 4
    private static let maxExcerptLength = 480
    /// Wider than the old 320 so the excerpt doesn't wrap into a tall, cramped ribbon — a
    /// readable measure for a transcript snippet without spilling off the popover.
    private static let cardWidth: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            HStack(spacing: MarginaliaSpacing.xs.value) {
                Text("S\(index)")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .accent)
                Text(source.title)
                    .marginaliaTextStyle(.headline, in: scheme, ink: .inkHeading)
            }

            if let friendlyDate {
                Text(friendlyDate)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }

            Text(clampedExcerpt)
                .marginaliaTextStyle(.body, in: scheme)
                .lineSpacing(2)
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
        .frame(maxWidth: Self.cardWidth, alignment: .leading)
    }

    private var clampedExcerpt: String {
        let excerpt = source.matchContext
        guard excerpt.count > Self.maxExcerptLength else { return excerpt }
        return String(excerpt.prefix(Self.maxExcerptLength)) + "…"
    }

    /// The meeting date rendered in a human format ("Jul 22, 2026, 3:45 PM") instead of the raw
    /// RFC3339/ISO-8601 string the recall engine carries on the wire. Parsing is tolerant of both
    /// fractional and whole-second forms; if the value isn't a parseable instant (other scopes may
    /// supply a different shape), fall back to the raw string rather than dropping it — never a
    /// fabricated or blanked date (No-Fake-State).
    private var friendlyDate: String? {
        guard let raw = source.meetingDate, !raw.isEmpty else { return nil }
        guard let date = Self.parseISO(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func parseISO(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private var personTags: some View {
        MarginaliaFlowLayout(spacing: MarginaliaSpacing.xs.value, lineSpacing: MarginaliaSpacing.xs.value) {
            ForEach(source.speakers.prefix(Self.maxPersonTags), id: \.self) { name in
                MarginaliaBadge(name, style: .neutral, symbol: "person", scheme: scheme)
            }
        }
    }
}
