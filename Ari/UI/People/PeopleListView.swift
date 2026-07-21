//
//  PeopleListView.swift — the full-width People screen (plan §2.2 People, §9 S6e; reworked
//  for the home + left-rail shell — see `MeetingsListView`'s header comment for the push-nav
//  rationale).
//
import AriKit
import AriViewModels
import SwiftUI

struct PeopleListView: View {
    let database: AppDatabase

    @State private var viewModel: PeopleListViewModel

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(initialValue: PeopleListViewModel(database: database))
    }

    var body: some View {
        CardListScaffold(
            state: viewModel.state,
            emptyTitle: "No people yet",
            emptyMessage: "People from meetings and calendar attendees will show up here.",
            navigationTitle: "People",
            destination: { $0.id },
            rowTitle: { $0.displayName },
            rowMetadata: metadata(for:)
        )
        .task { await viewModel.observe() }
    }

    private func metadata(for person: Person) -> String? {
        if person.isOwner {
            return "You"
        }
        return person.role ?? person.organization
    }
}
