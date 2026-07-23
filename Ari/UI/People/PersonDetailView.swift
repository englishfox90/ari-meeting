//
//  PersonDetailView.swift — voiceprint header + identity editing + bucketed facts + reverse
//  meetings list (docs/plans/people-view-parity.md §2.5 Slice 4; ← `frontend/src/app/
//  person-details/page.tsx`).
//
//  No-Fake-State: the header's voiceprint ring only renders when a real enrolled signature
//  exists; otherwise honest copy explains how to enroll one. Fact buckets render an honest
//  empty state for "Active facts" rather than hiding the section.
//
import AriKit
import AriViewModels
import SwiftUI

struct PersonDetailView: View {
    let database: AppDatabase
    let personId: PersonID

    @State private var viewModel: PersonDetailViewModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    // Identity form (in-progress edits, synced from the loaded person on load).
    @State private var formName = ""
    @State private var formEmail = ""
    @State private var formRole = ""
    @State private var formDomain = ""
    @State private var formNotes = ""
    @State private var isSavingIdentity = false
    @State private var identityError: String?

    // Manual fact composer.
    @State private var manualFactText = ""
    @State private var manualFactKind: FactKind = .other
    @State private var isAddingFact = false

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
        .background(MarginaliaCanvasWash(scheme: scheme))
        .navigationTitle(viewModel.person.value?.displayName ?? "Person")
        .task(id: personId) {
            await viewModel.load(personId)
            syncFormFromLoadedPerson()
        }
    }

    private func content(for person: Person) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
                header(for: person)
                identityAndFactsColumns
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                meetingsSection
            }
            .padding(MarginaliaSpacing.lg.value)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private func header(for person: Person) -> some View {
        HStack(alignment: .top, spacing: MarginaliaSpacing.md.value) {
            if let signature = viewModel.signature {
                VoiceprintGlyph(signature: signature, size: 120)
            }
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(person.isOwner ? "YOU" : "PERSON")
                    .marginaliaTextStyle(.caption, in: scheme)
                Text(person.displayName)
                    .marginaliaTextStyle(.title1, in: scheme, ink: .inkHeading)
                Text(
                    viewModel.meetingCount > 0
                        ? "Linked to \(viewModel.meetingCount) \(viewModel.meetingCount == 1 ? "meeting" : "meetings")."
                        : "Not yet linked to any meetings."
                )
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                if viewModel.signature == nil {
                    Text("No voiceprint yet — assign them in a meeting's Review speakers to enroll their voice.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            Button("Back to People") { dismiss() }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Two-column body

    private var identityAndFactsColumns: some View {
        HStack(alignment: .top, spacing: MarginaliaSpacing.lg.value) {
            identitySection
                .frame(width: 320, alignment: .leading)
            factsSection
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Identity (left column)

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text("Identity")
                    .marginaliaTextStyle(.headline, in: scheme)
                Text("What you know and have authored about this person.")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }

            identityField("Name", text: $formName)
            emailField
            identityField("Role", text: $formRole)
            identityField("Domain / focus", text: $formDomain)
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text("NOTES")
                    .marginaliaTextStyle(.caption, in: scheme)
                MarginaliaTextEditor(text: $formNotes, prompt: "Notes", scheme: scheme)
            }

            if let identityError {
                Text(identityError)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .accent)
            }

            Button(isSavingIdentity ? "Saving…" : "Save identity") {
                isSavingIdentity = true
                identityError = nil
                Task {
                    identityError = await viewModel.saveIdentity(
                        name: formName, email: formEmail, role: formRole, domain: formDomain, notes: formNotes
                    )
                    isSavingIdentity = false
                }
            }
            .buttonStyle(.marginalia(.primary, .regular, in: scheme))
            .disabled(isSavingIdentity || formName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(MarginaliaSpacing.md.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    private func identityField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(label.uppercased())
                .marginaliaTextStyle(.caption, in: scheme)
            MarginaliaTextField(text: text, prompt: label, scheme: scheme)
        }
    }

    /// Email is the identity key used to match calendar attendees, so once a person has one it is
    /// locked (read-only) — correcting a wrong email is a merge/heal operation, not a free-text
    /// edit that would silently split identity. Editable (and validated) only while still unset.
    @ViewBuilder
    private var emailField: some View {
        let isLocked = !(viewModel.person.value?.email ?? "").isEmpty
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            HStack(spacing: MarginaliaSpacing.xs.value) {
                Text("EMAIL")
                    .marginaliaTextStyle(.caption, in: scheme)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
                }
            }
            MarginaliaTextField(text: $formEmail, prompt: "Email", scheme: scheme)
                .disabled(isLocked)
                .opacity(isLocked ? 0.6 : 1)
            if isLocked {
                Text("Locked — email is the identity key. Correcting it is a merge operation.")
                    .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
        }
    }

    private func syncFormFromLoadedPerson() {
        guard let person = viewModel.person.value else { return }
        formName = person.displayName
        formEmail = person.email ?? ""
        formRole = person.role ?? ""
        formDomain = person.domain ?? ""
        formNotes = person.notes ?? ""
    }

    // MARK: - Facts (right column)

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
            if !viewModel.pendingFacts.isEmpty {
                factBucket(
                    title: "Pending confirmation",
                    subtitle: nil,
                    facts: viewModel.pendingFacts,
                    confirmLabel: "Confirm",
                    rejectLabel: "Reject",
                    onConfirm: { id in Task { await viewModel.confirmFact(id) } },
                    onReject: { id in Task { await viewModel.rejectFact(id) } }
                )
            }

            if !viewModel.needsReviewFacts.isEmpty {
                factBucket(
                    title: "Needs review",
                    subtitle: "Confirmed facts you haven't reaffirmed in over four weeks. "
                        + "Reaffirm the ones still true, or dismiss the ones that have gone stale.",
                    facts: viewModel.needsReviewFacts,
                    confirmLabel: "Reaffirm",
                    rejectLabel: "Dismiss",
                    onConfirm: { id in Task { await viewModel.reaffirm(id) } },
                    onReject: { id in Task { await viewModel.dismiss(id) } }
                )
            }

            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text("ACTIVE FACTS")
                    .marginaliaTextStyle(.caption, in: scheme)
                if viewModel.activeFacts.isEmpty {
                    emptyFactsCopy(
                        "No confirmed facts yet",
                        "Facts extracted from meetings, or added manually, will appear here once confirmed."
                    )
                } else {
                    factCard(viewModel.activeFacts)
                }
            }

            manualFactComposer

            if !viewModel.otherFacts.isEmpty {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    Text("SUPERSEDED / REJECTED")
                        .marginaliaTextStyle(.caption, in: scheme)
                    factCard(viewModel.otherFacts)
                }
            }
        }
    }

    private func factBucket(
        title: String,
        subtitle: String?,
        facts: [ProfileFact],
        confirmLabel: String,
        rejectLabel: String,
        onConfirm: @escaping (ProfileFactID) -> Void,
        onReject: @escaping (ProfileFactID) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(title.uppercased())
                .marginaliaTextStyle(.caption, in: scheme)
            if let subtitle {
                Text(subtitle)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }
            factCard(
                facts, confirmLabel: confirmLabel, rejectLabel: rejectLabel,
                onConfirm: onConfirm, onReject: onReject
            )
        }
    }

    private func factCard(
        _ facts: [ProfileFact],
        confirmLabel: String = "Confirm",
        rejectLabel: String = "Reject",
        onConfirm: ((ProfileFactID) -> Void)? = nil,
        onReject: ((ProfileFactID) -> Void)? = nil
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(facts) { fact in
                FactRow(
                    fact: fact,
                    confirmLabel: confirmLabel,
                    rejectLabel: rejectLabel,
                    onConfirm: onConfirm.map { action in { action(fact.id) } },
                    onReject: onReject.map { action in { action(fact.id) } },
                    provenance: { await viewModel.provenance(for: fact.id) }
                )
                if fact.id != facts.last?.id {
                    Divider().overlay(Color.marginalia(.hairline, in: scheme))
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    private func emptyFactsCopy(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(title)
                .marginaliaTextStyle(.body, in: scheme)
            Text(message)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    // MARK: - Add a fact manually

    private var manualFactComposer: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text("ADD A FACT MANUALLY")
                .marginaliaTextStyle(.caption, in: scheme)
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                MarginaliaTextEditor(
                    text: $manualFactText,
                    prompt: "e.g. Leads the platform migration project",
                    scheme: scheme,
                    minHeight: 44
                )
                HStack(spacing: MarginaliaSpacing.sm.value) {
                    Picker("Kind", selection: $manualFactKind) {
                        ForEach(Self.factKinds, id: \.self) { kind in
                            Text(Self.factKindLabel(kind)).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()

                    Spacer()

                    Button(isAddingFact ? "Adding…" : "Add") {
                        isAddingFact = true
                        Task {
                            await viewModel.addManualFact(text: manualFactText, kind: manualFactKind)
                            manualFactText = ""
                            manualFactKind = .other
                            isAddingFact = false
                        }
                    }
                    .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                    .disabled(isAddingFact || manualFactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(MarginaliaSpacing.md.value)
            .background {
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .fill(Color.marginalia(.elevated, in: scheme))
            }
        }
    }

    static let factKinds: [FactKind] = [.goal, .interest, .project, .roleSignal, .other]

    static func factKindLabel(_ kind: FactKind) -> String {
        switch kind {
        case .goal: "Goal"
        case .interest: "Interest"
        case .project: "Project"
        case .roleSignal: "Role signal"
        case .other: "Other"
        case let .unknown(raw): raw
        }
    }

    // MARK: - Meetings

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

// MARK: - FactRow

/// One fact row: kind/origin/status pills, text, provenance summary, and an optional lazy-
/// loaded "Seen in N meetings" expansion — never fabricated (No-Fake-State).
private struct FactRow: View {
    let fact: ProfileFact
    let confirmLabel: String
    let rejectLabel: String
    let onConfirm: (() -> Void)?
    let onReject: (() -> Void)?
    let provenance: () async -> ProfileFactWithProvenance?

    @Environment(\.colorScheme) private var scheme
    @State private var sourcesExpanded = false
    @State private var sources: [ProfileFactSource]?
    @State private var sourcesLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            HStack(alignment: .top, spacing: MarginaliaSpacing.sm.value) {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    pills
                    Text(fact.factText)
                        .marginaliaTextStyle(.body, in: scheme)
                    provenanceLine
                    if fact.sourceCount > 1 {
                        sourcesToggle
                    }
                }
                Spacer(minLength: MarginaliaSpacing.sm.value)
                if onConfirm != nil || onReject != nil {
                    HStack(spacing: MarginaliaSpacing.xs.value) {
                        if let onReject {
                            Button(rejectLabel, action: onReject)
                                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                        }
                        if let onConfirm {
                            Button(confirmLabel, action: onConfirm)
                                .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                        }
                    }
                }
            }
        }
        .padding(MarginaliaSpacing.md.value)
    }

    private var pills: some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            pill(PersonDetailView.factKindLabel(fact.factKind))
            pill(fact.origin == .selfReported ? "Self-reported" : "Attributed")
            if fact.status != .active {
                pill(fact.status.rawValue)
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            .padding(.horizontal, MarginaliaSpacing.xs.value)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(Color.marginalia(.selectionWash, in: scheme))
            }
    }

    private var provenanceLine: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            if let title = fact.sourceMeetingTitle {
                Text("From \(title)")
            }
            Text("Confidence \(Int((fact.confidence * 100).rounded()))%")
        }
        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
    }

    private var sourcesToggle: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Button(sourcesExpanded ? "Hide" : "Seen in \(fact.sourceCount) meetings") {
                sourcesExpanded.toggle()
                guard sourcesExpanded, sources == nil, !sourcesLoading else { return }
                sourcesLoading = true
                Task {
                    sources = await provenance()?.sources ?? []
                    sourcesLoading = false
                }
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))

            if sourcesExpanded {
                if sourcesLoading {
                    Text("Loading sources…")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                } else if let sources {
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                        ForEach(sources, id: \.id) { source in
                            HStack(spacing: MarginaliaSpacing.xs.value) {
                                Text(sourceMeetingLabel(source))
                                    .marginaliaTextStyle(.callout, in: scheme)
                                pill(relationLabel(source.relation))
                                Text("\(Int((source.confidence * 100).rounded()))%")
                                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sourceMeetingLabel(_ source: ProfileFactSource) -> String {
        if let title = source.meetingTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return source.meetingId != nil ? "Untitled meeting" : "Manual entry"
    }

    private func relationLabel(_ relation: FactSourceRelation) -> String {
        switch relation {
        case .origin: "first seen"
        case .reaffirmed: "reaffirmed"
        case .carried: "carried forward"
        case let .unknown(raw): raw
        }
    }
}
