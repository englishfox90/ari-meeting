//
//  SeriesListView.swift — the Series list (content) column (plan §2.2 Series, §9 S6f).
//
import AriKit
import AriViewModels
import SwiftUI

struct SeriesListView: View {
    let database: AppDatabase
    @Binding var selection: SeriesID?

    @State private var viewModel: SeriesListViewModel
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, selection: Binding<SeriesID?>) {
        self.database = database
        _selection = selection
        _viewModel = State(initialValue: SeriesListViewModel(database: database))
    }

    var body: some View {
        StateContainer(
            state: viewModel.state,
            emptyTitle: "No series yet",
            emptyMessage: "Recurring meetings will be grouped into a series here."
        ) { series in
            List(series, selection: $selection) { item in
                CardRow(title: item.title, metadata: metadata(for: item))
                    .tag(item.id)
            }
            .listStyle(.sidebar)
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle("Series")
        .task { await viewModel.observe() }
    }

    private func metadata(for series: Series) -> String? {
        series.cadence ?? series.detectedType
    }
}
