//
//  SettingsVocabularySection.swift — the custom-vocabulary row + editor sheet, mounted inside the
//  existing Transcription `SettingsGroup` (docs/plans/custom-vocabulary.md §2.5/§8 Step 5).
//
//  A `SettingsRow` shows the real enabled/cap count and opens a Marginalia-themed sheet holding the
//  list editor (add / edit / delete / enable-toggle). Per the plan's editor-field-labelling
//  correctness affordance (§ non-negotiables), the term form GROUPS its fields by destination —
//  a "Recognition" group (fed to the recognizer) and a "Summary only" group ("Sometimes
//  mis-transcribed as" lives here, NEVER fed to the recognizer) — so a user cannot poison the
//  decoder by filling in the obvious box.
//
//  Rule 45 (`liquid-glass-adoption.md`) — the sheet paints NO background/material of its own; the
//  system supplies the glass. Content inside uses Marginalia text/fields as usual.
//
import AriKit
import AriViewModels
import SwiftUI

struct SettingsVocabularySection: View {
    let database: AppDatabase

    @State private var viewModel: VocabularyViewModel
    @State private var isPresented = false

    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase) {
        self.database = database
        _viewModel = State(initialValue: VocabularyViewModel(database: database))
    }

    var body: some View {
        SettingsRow(
            "Custom vocabulary",
            description: "Domain terms and names your Mac's speech recognizer should listen for."
        ) {
            HStack(spacing: MarginaliaSpacing.sm.value) {
                Text(countLabel)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                Button("Edit…") { isPresented = true }
                    .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            }
        }
        .task { await viewModel.observe() }
        .sheet(isPresented: $isPresented) {
            VocabularyEditorSheet(viewModel: viewModel)
        }
    }

    private var countLabel: String {
        "\(viewModel.enabledCount) of \(VocabularyBias.maxEnabledTerms) enabled"
    }
}

// MARK: - Editor sheet

private struct VocabularyEditorSheet: View {
    let viewModel: VocabularyViewModel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    /// One form at a time, one `.sheet(item:)`. Two `.sheet` modifiers on the same view is a
    /// known SwiftUI sharp edge (the second can silently fail to present), so add and edit are
    /// unified into a single item-driven sheet.
    private enum ActiveForm: Identifiable {
        case add
        case edit(VocabularyTerm)
        var id: String {
            switch self {
            case .add: "add"
            case let .edit(term): "edit-\(term.id.rawValue)"
            }
        }
    }

    @State private var activeForm: ActiveForm?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                honestStateBanner
                    .padding(.horizontal, MarginaliaSpacing.md.value)
                    .padding(.top, MarginaliaSpacing.sm.value)

                if viewModel.terms.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.terms) { term in
                            termRow(term)
                                .contentShape(Rectangle())
                                .onTapGesture { activeForm = .edit(term) }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                let id = viewModel.terms[index].id
                                Task { await viewModel.delete(id) }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Custom vocabulary")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        activeForm = .add
                    } label: {
                        Label("Add term", systemImage: "plus")
                    }
                    .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                    .disabled(viewModel.isAtCap)
                }
            }
            .sheet(item: $activeForm) { form in
                switch form {
                case .add:
                    VocabularyTermFormSheet(existing: nil, viewModel: viewModel)
                case let .edit(term):
                    VocabularyTermFormSheet(existing: term, viewModel: viewModel)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    /// No-Fake-State: applies-to-next-recording is always shown (the real once-per-session
    /// snapshot semantics, §3 of the plan); the dropped-variant count is shown ONLY when it is
    /// genuinely nonzero — never a fabricated "0 dropped" line.
    @ViewBuilder
    private var honestStateBanner: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text("Changes apply to your next recording, not one already in progress.")
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            if viewModel.droppedVariantCount > 0 {
                Text(
                    "\(viewModel.droppedVariantCount) alternate form\(viewModel.droppedVariantCount == 1 ? "" : "s") won't be sent to the recognizer — you're over the built-in limit."
                )
                .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .marginaliaTextStyle(.caption, in: scheme, ink: .error)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MarginaliaSpacing.sm.value) {
            Spacer()
            Text("No custom vocabulary yet.")
                .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
            Text("Add proper nouns your Mac's speech recognizer tends to mishear.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func termRow(_ term: VocabularyTerm) -> some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(term.term)
                    .marginaliaTextStyle(.body, in: scheme)
                if let definition = term.definition, !definition.isEmpty {
                    Text(definition)
                        .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: MarginaliaSpacing.sm.value)
            Toggle("", isOn: Binding(
                get: { term.isEnabled },
                set: { newValue in Task { await viewModel.setEnabled(newValue, for: term.id) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, MarginaliaSpacing.xs.value)
    }
}

// MARK: - Add/edit form

/// One term's edit form. Four fields in two structural groups that teach the load-bearing
/// distinction ONCE each, instead of a caps caption per field (plan's editor-field-labelling
/// correctness affordance):
///   - **Recognition** — "Term" + "Also said as": correct forms, sent to the speech recognizer
///     (and used in summaries).
///   - **Summary only** — "What it is" + "Sometimes mis-transcribed as": never sent to the
///     recognizer; feeding a mis-hearing into the recognizer would bias IT TOWARD the error,
///     which the group's one quiet explanation line states.
/// The grouping is the safeguard: a mis-transcription physically lives in a group whose header
/// says it never reaches the recognizer.
private struct VocabularyTermFormSheet: View {
    let existing: VocabularyTerm?
    let viewModel: VocabularyViewModel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var term: String
    @State private var definition: String
    @State private var alternateForms: String
    @State private var misheardAs: String
    @State private var isEnabled: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(existing: VocabularyTerm?, viewModel: VocabularyViewModel) {
        self.existing = existing
        self.viewModel = viewModel
        _term = State(initialValue: existing?.term ?? "")
        _definition = State(initialValue: existing?.definition ?? "")
        _alternateForms = State(initialValue: (existing?.alternateForms ?? []).joined(separator: ", "))
        _misheardAs = State(initialValue: (existing?.misheardAs ?? []).joined(separator: ", "))
        _isEnabled = State(initialValue: existing?.isEnabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
            Text(existing == nil ? "Add term" : "Edit term")
                .marginaliaTextStyle(.title2, in: scheme)

            fieldGroup(
                eyebrow: "Recognition",
                explanation: "Sent to the speech recognizer so it listens for these. Also used in summaries."
            ) {
                labeledField("Term", text: $term, prompt: "e.g. Arivo")
                labeledField(
                    "Also said as",
                    text: $alternateForms,
                    prompt: "Other correct forms, comma-separated — e.g. Ari Kit"
                )
            }

            fieldGroup(
                eyebrow: "Summary only",
                explanation: "Never sent to the recognizer — a known mis-hearing there would bias it toward the error. Summaries use these to spell and explain the term."
            ) {
                labeledField("What it is", text: $definition, prompt: "One line, e.g. our meeting-notes app")
                labeledField(
                    "Sometimes mis-transcribed as",
                    text: $misheardAs,
                    prompt: "Known wrong transcriptions, comma-separated — e.g. Revo, Arrivo"
                )
            }

            MarginaliaToggleRow("Enabled", isOn: $isEnabled, scheme: scheme)

            if let errorMessage {
                Text(errorMessage)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: MarginaliaSpacing.md.value) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                    .disabled(isSaving || term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(MarginaliaSpacing.xl.value)
        .frame(width: 520)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDefinition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        let forms = Self.splitList(alternateForms)
        let mishearings = Self.splitList(misheardAs)

        Task {
            let error: String?
            if let existing {
                error = await viewModel.update(
                    existing,
                    term: trimmedTerm,
                    definition: trimmedDefinition.isEmpty ? nil : trimmedDefinition,
                    alternateForms: forms,
                    misheardAs: mishearings,
                    isEnabled: isEnabled
                )
            } else {
                error = await viewModel.add(
                    term: trimmedTerm,
                    definition: trimmedDefinition.isEmpty ? nil : trimmedDefinition,
                    alternateForms: forms,
                    misheardAs: mishearings,
                    isEnabled: isEnabled
                )
            }
            isSaving = false
            if let error {
                errorMessage = error
            } else {
                dismiss()
            }
        }
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// One of the two destination buckets: a quiet surface card introduced by an uppercase
    /// eyebrow (`.caption` — the ONLY caps on the sheet) and a single sentence-case explanation,
    /// so the recognizer-vs-summary distinction is stated once per group instead of per field.
    private func fieldGroup(
        eyebrow: String,
        explanation: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(eyebrow)
                    .marginaliaTextStyle(.caption, in: scheme)
                Text(explanation)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
        }
    }

    /// Sentence-case field label over a Marginalia text field — the `ImportMeetingSheet` idiom.
    private func labeledField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(label)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            MarginaliaTextField(text: text, prompt: prompt, scheme: scheme)
        }
    }
}
