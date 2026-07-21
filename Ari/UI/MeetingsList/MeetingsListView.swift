//
//  MeetingsListView.swift — the full-width Saved-meetings screen (home + left-rail rework).
//
//  Rows push `MeetingDetailView` via the shared detail `NavigationStack`'s
//  `navigationDestination(for: MeetingID.self)` (registered in `RootSplitView`) rather than a
//  third-column selection binding.
//
import AriKit
import AriViewModels
import SwiftUI

struct MeetingsListView: View {
    let database: AppDatabase

    @State private var viewModel: MeetingsListViewModel

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(initialValue: MeetingsListViewModel(database: database))
    }

    var body: some View {
        CardListScaffold(
            state: viewModel.state,
            emptyTitle: "No meetings yet",
            emptyMessage: "Recorded and imported meetings will show up here.",
            navigationTitle: "Saved meetings",
            destination: { $0.id },
            rowTitle: { $0.title },
            rowMetadata: { metadata(for: $0) }
        )
        .task { await viewModel.observe() }
    }

    private func metadata(for meeting: Meeting) -> String {
        meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
