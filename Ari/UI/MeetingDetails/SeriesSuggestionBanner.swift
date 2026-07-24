//
//  SeriesSuggestionBanner.swift — the meeting-header consent affordance for a detected recurring
//  series (docs/plans/calendar-series-intelligence.md §2.5, Feature 1).
//
//  Renders ONLY from `AddToSeriesViewModel.suggestedSeries` — a real, persisted `'suggested'`
//  membership row (`SeriesRepository.suggestedSeriesIds(forMeeting:)`), never an invented prompt
//  (No-Fake-State). One banner per pending suggestion (in practice at most one — F9 series
//  detection matches at most one recurrence key per meeting). Sits next to the existing
//  "Add to series" affordance in the meeting header.
//
//  Signal Rule: the amber-filled "confirm" button is the one deliberate use of accent here — it's
//  the genuine one-thing-that-matters moment (a consent decision); "No thanks" stays quiet.
//
import AriKit
import AriViewModels
import SwiftUI

struct SeriesSuggestionBanner: View {
    let viewModel: AddToSeriesViewModel
    let meetingId: MeetingID

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            ForEach(viewModel.suggestedSeries) { series in
                suggestion(series)
            }
        }
    }

    private func suggestion(_ series: SeriesSummary) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                Text("This looks like an occurrence of the recurring series “\(series.title)”.")
                    .marginaliaTextStyle(.body, in: scheme)
                Spacer(minLength: 0)
            }
            HStack(spacing: MarginaliaSpacing.sm.value) {
                Button("Add — and add future occurrences") {
                    Task { await viewModel.confirmSuggestion(seriesId: series.id, meetingId: meetingId) }
                }
                .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                .disabled(viewModel.isBusy)

                Button("No thanks") {
                    Task { await viewModel.declineSuggestion(seriesId: series.id, meetingId: meetingId) }
                }
                .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                .disabled(viewModel.isBusy)
            }
        }
        .padding(MarginaliaSpacing.md.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
        }
    }
}
