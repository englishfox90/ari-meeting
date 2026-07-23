//
//  AskSeriesCard.swift — the inline "resolved series" entity card rendered above an assistant
//  answer (docs/plans/ask-meetings-tools-and-cards.md §5.2), sibling to `AskSourceCard.swift`.
//  Renders ONLY from a real, deterministically resolved `SeriesCardPayload` (Slice B's
//  `RecallTools.findSeries`/`meetings(inSeries:limit:)` + the real, un-capped `meetingCount`) —
//  the "last on" clause is omitted entirely when there's no real `lastMeetingDate` (No-Fake-State,
//  §5.3).
//
import AriKit
import SwiftUI

struct AskSeriesCard: View {
    let payload: SeriesCardPayload
    let onOpenSeries: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text(payload.title)
                .marginaliaTextStyle(.headline, in: scheme, ink: .inkHeading)

            Text(metaLine)
                .marginaliaTextStyle(.body, in: scheme)

            Button {
                onOpenSeries(payload.seriesId)
            } label: {
                Label("Open series", systemImage: "arrow.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    /// "N meeting(s), last on `<date>`" — real, un-estimated count; the "last on" clause is
    /// omitted entirely when there's no real `lastMeetingDate`.
    private var metaLine: String {
        RecallCardDisplay.seriesMetaLine(
            meetingCount: payload.meetingCount,
            lastMeetingDate: payload.lastMeetingDate
        )
    }
}
