//
//  SeriesListView.swift — the full-width Series screen: a searchable, alphabetically-sorted list
//  of recurring meeting series, each row carrying its member count + most-recent-meeting date
//  (plan §2.2 Series, §9 S6f).
//
//  Rows are `SeriesSummary` (the count/last-meeting aggregates the domain `Series` omits). The
//  list is sorted alphabetically by the repository and filtered client-side by the search field,
//  so a long series list stays navigable. Every row's metadata is real (No-Fake-State — the
//  "Last …" clause is dropped when a series has no meetings).
//
import AriKit
import AriViewModels
import SwiftUI

struct SeriesListView: View {
    let database: AppDatabase

    @State private var viewModel: SeriesListViewModel
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(initialValue: SeriesListViewModel(database: database))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        return StateContainer(
            state: viewModel.state,
            emptyTitle: "No series yet",
            emptyMessage: "Recurring meetings will be grouped into a series here."
        ) { _ in
            loadedContent(searchText: $viewModel.searchText)
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle("Series")
        .task { await viewModel.observe() }
    }

    private func loadedContent(searchText: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MarginaliaSearchField(text: searchText, prompt: "Search series", scheme: scheme)
                .padding(.horizontal, MarginaliaSpacing.md.value)
                .padding(.bottom, MarginaliaSpacing.md.value)
            Divider().overlay(Color.marginalia(.hairline, in: scheme))
            if viewModel.hasNoMatches {
                noMatches
            } else {
                List(viewModel.filtered) { summary in
                    NavigationLink(value: summary.id) {
                        CardRow(title: summary.title, metadata: metadata(for: summary))
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text("Recurring")
                .marginaliaTextStyle(.caption, in: scheme)
            Text("Series")
                .marginaliaTextStyle(.title1, in: scheme, ink: .inkHeading)
            Text("Recurring meetings grouped into a connected record.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.top, MarginaliaSpacing.lg.value)
        .padding(.bottom, MarginaliaSpacing.md.value)
    }

    private var noMatches: some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            Text("No matching series")
                .marginaliaTextStyle(.body, in: scheme)
            Text("No series match “\(viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }

    /// "N meetings · Last <relative>" — a real count and a relative last-meeting date; the "Last …"
    /// clause is dropped when the series has no meetings (No-Fake-State).
    private func metadata(for summary: SeriesSummary) -> String {
        let countText = "\(summary.meetingCount) meeting\(summary.meetingCount == 1 ? "" : "s")"
        guard let last = summary.lastMeetingTime else { return countText }
        let relative = Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
        return "\(countText) · Last \(relative)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
