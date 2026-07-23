//
//  MeetingsListView.swift — the full-width Saved-meetings screen (home + left-rail rework).
//
//  Rows push `MeetingDetailView` via the shared detail `NavigationStack`'s
//  `navigationDestination(for: MeetingID.self)` (registered in `RootSplitView`) rather than a
//  third-column selection binding. Each row carries a right-click menu to rename or delete the
//  meeting; the list refreshes itself from the view model's live observation after either.
//
import AriKit
import AriViewModels
import SwiftUI

struct MeetingsListView: View {
    let database: AppDatabase

    @State private var viewModel: MeetingsListViewModel
    @State private var renameTarget: Meeting?
    @State private var renameText: String = ""
    @State private var deleteTarget: Meeting?
    @State private var actionError: String?

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
            rowMetadata: { metadata(for: $0) },
            rowMenu: { AnyView(rowMenu(for: $0)) }
        )
        .task { await viewModel.observe() }
        .alert("Rename meeting", isPresented: renamePresented) {
            TextField("Meeting name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: deletePresented,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { meeting in
            Button("Delete \u{201C}\(meeting.title)\u{201D}", role: .destructive) { commitDelete(meeting) }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("It will be removed from your saved meetings. This can't be undone here.")
        }
        .alert("Couldn't complete that", isPresented: errorPresented) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private func rowMenu(for meeting: Meeting) -> some View {
        Button {
            renameText = meeting.title
            renameTarget = meeting
        } label: {
            Label("Rename\u{2026}", systemImage: "pencil")
        }
        Button(role: .destructive) {
            deleteTarget = meeting
        } label: {
            Label("Delete\u{2026}", systemImage: "trash")
        }
    }

    private func commitRename() {
        guard let meeting = renameTarget else { return }
        let newTitle = renameText
        renameTarget = nil
        Task {
            do { try await viewModel.rename(meeting, to: newTitle) }
            catch { actionError = String(describing: error) }
        }
    }

    private func commitDelete(_ meeting: Meeting) {
        deleteTarget = nil
        Task {
            do { try await viewModel.delete(meeting) }
            catch { actionError = String(describing: error) }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: {
            if !$0 {
                renameTarget = nil
            }
        })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: {
            if !$0 {
                deleteTarget = nil
            }
        })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { actionError != nil }, set: {
            if !$0 {
                actionError = nil
            }
        })
    }

    private func metadata(for meeting: Meeting) -> String {
        meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
