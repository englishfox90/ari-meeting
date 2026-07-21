//
//  PersonDetailView.swift — authored Person fields + participant meetings (honestly empty
//  today — plan §9 S6e; see `PersonDetailViewModel`'s file-header TODO(S6)).
//
import AriKit
import AriViewModels
import SwiftUI

struct PersonDetailView: View {
    let database: AppDatabase
    let personId: PersonID

    @State private var viewModel: PersonDetailViewModel
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, personId: PersonID) {
        self.database = database
        self.personId = personId
        _viewModel = State(initialValue: PersonDetailViewModel(database: database))
    }

    /// No own `NavigationStack`: pushed onto the shell's outer stack (which owns the MeetingID
    /// destination); participant-meeting rows push via `NavigationLink(value:)`.
    var body: some View {
        StateContainer(
            state: viewModel.person,
            emptyTitle: "No person",
            emptyMessage: nil
        ) { person in
            content(for: person)
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle(viewModel.person.value?.displayName ?? "Person")
        .task(id: personId) {
            await viewModel.load(personId)
        }
    }

    private func content(for person: Person) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                header(for: person)
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                meetingsSection
            }
            .padding(MarginaliaSpacing.md.value)
        }
    }

    private func header(for person: Person) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(person.displayName)
                .marginaliaTextStyle(.title1, in: scheme)
            if person.isOwner {
                Text("You")
                    .marginaliaTextStyle(.callout, in: scheme)
            }
            if let role = person.role {
                Text(role)
                    .marginaliaTextStyle(.callout, in: scheme)
            }
            if let organization = person.organization {
                Text(organization)
                    .marginaliaTextStyle(.callout, in: scheme)
            }
            if let email = person.email {
                Text(email)
                    .marginaliaTextStyle(.callout, in: scheme)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var meetingsSection: some View {
        SectionHeader(title: "Meetings")
        if viewModel.participantMeetings.isEmpty {
            Text("No meetings linked to this person yet.")
                .marginaliaTextStyle(.callout, in: scheme)
                .padding(.horizontal, MarginaliaSpacing.md.value)
        } else {
            VStack(spacing: 0) {
                ForEach(viewModel.participantMeetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        CardRow(
                            title: meeting.title,
                            metadata: meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
