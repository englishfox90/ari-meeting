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
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(initialValue: PeopleListViewModel(database: database))
    }

    var body: some View {
        StateContainer(
            state: viewModel.state,
            emptyTitle: "No people yet",
            emptyMessage: "People from meetings and calendar attendees will show up here."
        ) { people in
            List(people) { person in
                NavigationLink(value: person.id) {
                    CardRow(title: person.displayName, metadata: metadata(for: person))
                }
            }
            .listStyle(.inset)
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle("People")
        .task { await viewModel.observe() }
    }

    private func metadata(for person: Person) -> String? {
        if person.isOwner {
            return "You"
        }
        return person.role ?? person.organization
    }
}
