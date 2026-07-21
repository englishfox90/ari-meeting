//
//  SeriesListView.swift — the full-width Series screen (plan §2.2 Series, §9 S6f; reworked
//  for the home + left-rail shell — see `MeetingsListView`'s header comment for the push-nav
//  rationale).
//
import AriKit
import AriViewModels
import SwiftUI

struct SeriesListView: View {
    let database: AppDatabase

    @State private var viewModel: SeriesListViewModel

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(initialValue: SeriesListViewModel(database: database))
    }

    var body: some View {
        CardListScaffold(
            state: viewModel.state,
            emptyTitle: "No series yet",
            emptyMessage: "Recurring meetings will be grouped into a series here.",
            navigationTitle: "Series",
            destination: { $0.id },
            rowTitle: { $0.title },
            rowMetadata: metadata(for:)
        )
        .task { await viewModel.observe() }
    }

    private func metadata(for series: Series) -> String? {
        series.cadence ?? series.detectedType
    }
}
