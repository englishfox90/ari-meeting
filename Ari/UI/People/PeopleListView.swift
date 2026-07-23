//
//  PeopleListView.swift — the full-width People screen: searchable roster, owner card, and
//  cross-person pending-facts review (docs/plans/people-view-parity.md §2.5 Slice 3;
//  ← `frontend/src/app/people/page.tsx`).
//
//  A bespoke screen (not `CardListScaffold` — the owner card + pending-review section have no
//  analog there). Every row's badges/glyph are real data (No-Fake-State): a person with no
//  enrolled voiceprint shows no glyph at all, and the "N pending"/"N facts" badges only appear
//  when the count is actually non-zero.
//
import AriKit
import AriViewModels
import SwiftUI

struct PeopleListView: View {
    let database: AppDatabase

    @State private var viewModel: PeopleListViewModel
    @State private var ownerSheetPresented = false
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(initialValue: PeopleListViewModel(database: database))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        return ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
                header
                MarginaliaSearchField(text: $viewModel.searchText, prompt: "Search people", scheme: scheme)
                ownerCard
                if !viewModel.pendingFacts.isEmpty {
                    pendingFactsSection
                }
                peopleSection
            }
            .padding(MarginaliaSpacing.lg.value)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MarginaliaCanvasWash(scheme: scheme))
        .navigationTitle("People")
        .task { await viewModel.observe() }
        .sheet(isPresented: $ownerSheetPresented) {
            OwnerEditSheet(owner: viewModel.owner) { form in
                await viewModel.saveOwner(
                    displayName: form.displayName,
                    email: form.email,
                    role: form.role,
                    organization: form.organization,
                    domain: form.domain,
                    notes: form.notes
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text("PEOPLE")
                .marginaliaTextStyle(.caption, in: scheme)
            Text("People")
                .marginaliaTextStyle(.title1, in: scheme, ink: .inkHeading)
            Text("Profiles built from calendar attendees and meeting facts — nothing is inferred without a source.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Owner card

    private var ownerCard: some View {
        HStack(alignment: .top, spacing: MarginaliaSpacing.sm.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text("YOU")
                    .marginaliaTextStyle(.caption, in: scheme)
                if let owner = viewModel.owner {
                    Text(owner.displayName)
                        .marginaliaTextStyle(.headline, in: scheme)
                    Text(owner.role ?? "No role set yet")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                } else {
                    Text("No owner profile yet")
                        .marginaliaTextStyle(.headline, in: scheme)
                    Text("Set up your profile so summaries can be written with you in mind.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            Button(viewModel.owner == nil ? "Set up profile" : "Edit owner profile") {
                ownerSheetPresented = true
            }
            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
        }
        .padding(MarginaliaSpacing.md.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    // MARK: - Pending facts (collapsible)

    @State private var pendingExpanded = false

    private var pendingFactsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                pendingExpanded.toggle()
            } label: {
                HStack(spacing: MarginaliaSpacing.sm.value) {
                    Text("\(viewModel.pendingFacts.count)")
                        .marginaliaTextStyle(.caption, in: scheme, ink: .canvas)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(Color.marginalia(.accent, in: scheme)))
                    Text("Review pending \(viewModel.pendingFacts.count == 1 ? "fact" : "facts")")
                        .marginaliaTextStyle(.body, in: scheme)
                    Spacer()
                    Image(systemName: pendingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                }
                .padding(MarginaliaSpacing.md.value)
            }
            .buttonStyle(.plain)

            if pendingExpanded {
                VStack(spacing: 0) {
                    ForEach(viewModel.pendingFacts, id: \.fact.id) { item in
                        pendingFactRow(item)
                        if item.fact.id != viewModel.pendingFacts.last?.fact.id {
                            Divider().overlay(Color.marginalia(.hairline, in: scheme))
                        }
                    }
                }
                .padding(.horizontal, MarginaliaSpacing.md.value)
                .padding(.bottom, MarginaliaSpacing.md.value)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    private func pendingFactRow(_ item: ProfileFactWithPerson) -> some View {
        HStack(alignment: .top, spacing: MarginaliaSpacing.sm.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                NavigationLink(value: item.personId) {
                    Text(item.personDisplayName)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .accent)
                }
                .buttonStyle(.plain)
                Text(item.fact.factText)
                    .marginaliaTextStyle(.body, in: scheme)
                if let title = item.fact.sourceMeetingTitle {
                    Text("From \(title)")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            HStack(spacing: MarginaliaSpacing.xs.value) {
                Button("Reject") {
                    Task { await viewModel.rejectPendingFact(item.fact.id) }
                }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                Button("Confirm") {
                    Task { await viewModel.confirmPendingFact(item.fact.id) }
                }
                .buttonStyle(.marginalia(.primary, .regular, in: scheme))
            }
        }
        .padding(.vertical, MarginaliaSpacing.sm.value)
    }

    // MARK: - People roster

    @ViewBuilder
    private var peopleSection: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(MarginaliaSpacing.xl.value)
        case let .failed(message):
            failedView(message)
        case .empty, .loaded:
            if viewModel.hasNoMatches {
                noMatchesView
            } else if viewModel.filtered.isEmpty {
                emptyPeopleView
            } else {
                peopleList
            }
        }
    }

    private var peopleList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.filtered) { person in
                NavigationLink(value: person.id) {
                    personRow(person)
                }
                .buttonStyle(.plain)
                if person.id != viewModel.filtered.last?.id {
                    Divider().overlay(Color.marginalia(.hairline, in: scheme))
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    private func personRow(_ person: Person) -> some View {
        let counts = viewModel.factCounts[person.id]
        return HStack(spacing: MarginaliaSpacing.sm.value) {
            if let signature = viewModel.signatures[person.id] {
                VoiceprintGlyph(signature: signature, size: 28)
            }
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(person.displayName)
                    .marginaliaTextStyle(.body, in: scheme)
                    .lineLimit(1)
                Text(person.role ?? person.email ?? "No details yet")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            if let counts, counts.pending > 0 {
                badge("\(counts.pending) pending", ink: .accent)
            }
            if let counts, counts.active > 0 {
                badge("\(counts.active) \(counts.active == 1 ? "fact" : "facts")", ink: .inkSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
        }
        .padding(MarginaliaSpacing.md.value)
    }

    private func badge(_ text: String, ink: MarginaliaColorRole) -> some View {
        Text(text)
            .marginaliaTextStyle(.caption, in: scheme, ink: ink)
            .padding(.horizontal, MarginaliaSpacing.xs.value)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(Color.marginalia(.selectionWash, in: scheme))
            }
    }

    private var emptyPeopleView: some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            Text("No people yet")
                .marginaliaTextStyle(.body, in: scheme)
            Text("They'll appear here as you sync calendar events and link meetings.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }

    private var noMatchesView: some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            Text("No matching people")
                .marginaliaTextStyle(.body, in: scheme)
            Text("No one matches “\(viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            Label {
                Text(message)
                    .marginaliaTextStyle(.body, in: scheme, ink: .error)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.marginalia(.error, in: scheme))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(MarginaliaSpacing.xl.value)
    }
}

// MARK: - Owner edit sheet

/// The owner-identity form fields, decoupled from `Person` so the sheet can hold in-progress
/// edits without mutating the view model until Save.
struct OwnerFormFields {
    var displayName: String
    var email: String?
    var role: String?
    var organization: String?
    var domain: String?
    var notes: String?
}

private struct OwnerEditSheet: View {
    let owner: Person?
    /// Returns `nil` on success (the sheet then dismisses), or an error message to surface inline
    /// while keeping the sheet open (No-Fake-State: a failed save must not look like it worked).
    let onSave: (OwnerFormFields) async -> String?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var email: String
    @State private var role: String
    @State private var organization: String
    @State private var domain: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(owner: Person?, onSave: @escaping (OwnerFormFields) async -> String?) {
        self.owner = owner
        self.onSave = onSave
        _displayName = State(initialValue: owner?.displayName ?? "")
        _email = State(initialValue: owner?.email ?? "")
        _role = State(initialValue: owner?.role ?? "")
        _organization = State(initialValue: owner?.organization ?? "")
        _domain = State(initialValue: owner?.domain ?? "")
        _notes = State(initialValue: owner?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                    field("Name", text: $displayName)
                    field("Email", text: $email)
                    field("Role", text: $role)
                    field("Organization", text: $organization)
                    field("Domain / focus", text: $domain)
                    field("Notes", text: $notes)

                    if let errorMessage {
                        Text(errorMessage)
                            .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                            .padding(.top, MarginaliaSpacing.xs.value)
                    }
                }
                .padding(MarginaliaSpacing.lg.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(MarginaliaCanvasWash(scheme: scheme))
            .navigationTitle(owner == nil ? "Set up profile" : "Edit owner profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        isSaving = true
                        errorMessage = nil
                        Task {
                            let error = await onSave(OwnerFormFields(
                                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                                email: nonEmpty(email),
                                role: nonEmpty(role),
                                organization: nonEmpty(organization),
                                domain: nonEmpty(domain),
                                notes: nonEmpty(notes)
                            ))
                            isSaving = false
                            if let error {
                                errorMessage = error
                            } else {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                    .disabled(isSaving || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 460)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(label.uppercased())
                .marginaliaTextStyle(.caption, in: scheme)
            MarginaliaTextField(text: text, prompt: label, scheme: scheme)
        }
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
