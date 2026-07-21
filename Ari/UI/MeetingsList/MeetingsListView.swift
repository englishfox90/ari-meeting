//
//  MeetingsListView.swift — the Meetings list (content) column (plan §2.2 MeetingsList).
//
import AriKit
import AriViewModels
import SwiftUI

struct MeetingsListView: View {
    let database: AppDatabase
    @Binding var selection: MeetingID?

    @State private var viewModel: MeetingsListViewModel
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, selection: Binding<MeetingID?>) {
        self.database = database
        _selection = selection
        _viewModel = State(initialValue: MeetingsListViewModel(database: database))
    }

    var body: some View {
        StateContainer(
            state: viewModel.state,
            emptyTitle: "No meetings yet",
            emptyMessage: "Recorded and imported meetings will show up here."
        ) { meetings in
            List(meetings, selection: $selection) { meeting in
                CardRow(title: meeting.title, metadata: metadata(for: meeting))
                    .tag(meeting.id)
            }
            .listStyle(.sidebar)
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle("Meetings")
        .task { await viewModel.observe() }
    }

    private func metadata(for meeting: Meeting) -> String {
        meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
