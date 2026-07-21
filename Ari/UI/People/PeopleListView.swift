//
//  PeopleListView.swift — the People list (content) column (plan §2.2 People, §9 S6e).
//
import AriKit
import AriViewModels
import SwiftUI

struct PeopleListView: View {
    let database: AppDatabase
    @Binding var selection: PersonID?

    @State private var viewModel: PeopleListViewModel
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, selection: Binding<PersonID?>) {
        self.database = database
        _selection = selection
        _viewModel = State(initialValue: PeopleListViewModel(database: database))
    }

    var body: some View {
        StateContainer(
            state: viewModel.state,
            emptyTitle: "No people yet",
            emptyMessage: "People from meetings and calendar attendees will show up here."
        ) { people in
            List(people, selection: $selection) { person in
                CardRow(title: person.displayName, metadata: metadata(for: person))
                    .tag(person.id)
            }
            .listStyle(.sidebar)
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
