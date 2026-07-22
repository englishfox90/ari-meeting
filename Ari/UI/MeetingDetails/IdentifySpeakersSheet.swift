//
//  IdentifySpeakersSheet.swift — the "Identify speakers" flow (docs/plans/arikit-diarization.md
//  §5 D9b, §6, §7).
//
//  Two explicit count-hint modes (H2) — never one ambiguous field: "Exactly N" maps to `.exact`;
//  "Not sure / at most N" (or an untouched calendar/participant prefill) always maps to
//  `.upperBound`. Progress is phase-labeled, driven only by real `DiarizationPhase` callbacks
//  (No-Fake-State). Results render per-cluster rows via `SpeakerAssignmentRow`; confirming an
//  assignment is the ONLY write path (invariant I1) — nothing is written by opening the sheet,
//  running, or browsing suggestions.
//
import AriKit
import AriViewModels
import SwiftUI

struct IdentifySpeakersSheet: View {
    let viewModel: SpeakerIdentificationViewModel
    let meetingId: MeetingID
    let audioURL: URL
    /// Resolved display name for a stamped speaker (from `MeetingDetailViewModel.speakerNames`,
    /// reloaded by `onSpeakersChanged` after a run/confirm) — `nil` when not yet known.
    let displayName: (SpeakerID) -> String?
    let createPerson: (String) async -> PersonID
    let onSpeakersChanged: () async -> Void
    let onDismiss: () -> Void

    private enum CountMode: String, CaseIterable, Identifiable, Hashable, Sendable {
        case exact, uncertain
        var id: String { rawValue }
        var title: String {
            switch self {
            case .exact: "Exactly"
            case .uncertain: "Not sure"
            }
        }
    }

    @Environment(\.colorScheme) private var scheme
    @State private var countMode: CountMode = .uncertain
    @State private var countText: String = ""
    @State private var suggestionsBySpeaker: [SpeakerID: [(personId: PersonID, score: Float)]] = [:]
    @State private var assignSpeakerId: SpeakerID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
                    countSection
                    progressSection
                    resultsSection
                }
                .padding(MarginaliaSpacing.lg.value)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.marginalia(.canvas, in: scheme))
            .navigationTitle("Identify speakers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .task {
            await viewModel.loadHint(for: meetingId)
            await viewModel.loadAssignablePeople()
            if countText.isEmpty, case let .upperBound(n) = viewModel.prefilledHint?.hint {
                countText = String(n)
                viewModel.setUncertainCount(n)
            }
        }
        .sheet(isPresented: Binding(
            get: { assignSpeakerId != nil },
            set: { if !$0 { assignSpeakerId = nil } }
        )) {
            if let speakerId = assignSpeakerId {
                AssignPersonSheet(
                    people: viewModel.assignablePeople,
                    suggestions: namedSuggestions(for: speakerId),
                    createPerson: createPerson,
                    onSelect: { personId in
                        Task {
                            await viewModel.confirm(speakerId, as: personId, inMeeting: meetingId)
                            await onSpeakersChanged()
                            assignSpeakerId = nil
                        }
                    },
                    onCancel: { assignSpeakerId = nil }
                )
            }
        }
    }

    // MARK: - Count hint

    private var countSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            SectionHeader(title: "How many speakers?")
            MarginaliaSegmentedControl(
                selection: Binding(
                    get: { countMode },
                    set: { newMode in
                        countMode = newMode
                        applyCount(countText)
                    }
                ),
                segments: CountMode.allCases.map { MarginaliaSegment(value: $0, title: $0.title) },
                scheme: scheme
            )
            HStack(spacing: MarginaliaSpacing.sm.value) {
                MarginaliaTextField(text: Binding(
                    get: { countText },
                    set: { newValue in
                        countText = newValue
                        applyCount(newValue)
                    }
                ), prompt: "Number of speakers", scheme: scheme)
                    .frame(width: 160)
                if let prefillCaption {
                    Text(prefillCaption)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
            Button("Identify speakers") {
                runTapped()
            }
            .buttonStyle(.marginalia(.primary, .large, in: scheme))
            .disabled(!viewModel.canRun || isRunning)
        }
    }

    private var prefillCaption: String? {
        guard let prefilledHint = viewModel.prefilledHint, prefilledHint.origin == .calendarAttendees else { return nil }
        guard case let .upperBound(n) = prefilledHint.hint else { return nil }
        return "From calendar/participants: \(n)"
    }

    private func applyCount(_ text: String) {
        guard let n = Int(text) else { return }
        switch countMode {
        case .exact: viewModel.setExactCount(n)
        case .uncertain: viewModel.setUncertainCount(n)
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        switch viewModel.runState {
        case let .running(phase, fraction):
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(phaseLabel(phase))
                    .marginaliaTextStyle(.callout, in: scheme)
                ProgressView(value: fraction)
            }
        case let .failed(message):
            Text(message)
                .marginaliaTextStyle(.callout, in: scheme, ink: .error)
        case .idle, .succeeded:
            EmptyView()
        }
    }

    private var isRunning: Bool {
        if case .running = viewModel.runState { return true }
        return false
    }

    private func phaseLabel(_ phase: DiarizationPhase) -> String {
        switch phase {
        case .preparingModels: "Preparing models…"
        case .decodingAudio: "Reading audio…"
        case .diarizing: "Separating voices…"
        case .matching: "Matching…"
        case .stamping: "Labeling transcript…"
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if case let .succeeded(result) = viewModel.runState {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                SectionHeader(title: "Speakers")
                VStack(spacing: 0) {
                    ForEach(result.speakers, id: \.speakerId) { resolved in
                        SpeakerAssignmentRow(
                            resolved: resolved,
                            resolvedName: resolved.tier == .autoConfirm ? displayName(resolved.speakerId) : nil,
                            suggestion: topSuggestion(for: resolved.speakerId),
                            onConfirmSuggestion: { confirmTopSuggestion(for: resolved.speakerId) },
                            onNotThem: { suggestionsBySpeaker[resolved.speakerId] = [] },
                            onAssign: { assignSpeakerId = resolved.speakerId }
                        )
                        Divider().overlay(Color.marginalia(.hairline, in: scheme))
                    }
                }
                if result.unresolvedRows > 0 {
                    Text("\(result.unresolvedRows) transcript rows could not be matched to a speaker.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
            }
        }
    }

    private func topSuggestion(for speakerId: SpeakerID) -> (personId: PersonID, name: String, score: Float)? {
        namedSuggestions(for: speakerId).first
    }

    private func namedSuggestions(for speakerId: SpeakerID) -> [(personId: PersonID, name: String, score: Float)] {
        (suggestionsBySpeaker[speakerId] ?? []).compactMap { suggestion in
            guard let name = viewModel.assignablePeople.first(where: { $0.id == suggestion.personId })?.displayName else {
                return nil
            }
            return (personId: suggestion.personId, name: name, score: suggestion.score)
        }
    }

    private func confirmTopSuggestion(for speakerId: SpeakerID) {
        guard let top = topSuggestion(for: speakerId) else { return }
        Task {
            await viewModel.confirm(speakerId, as: top.personId, inMeeting: meetingId)
            await onSpeakersChanged()
        }
    }

    private func runTapped() {
        Task {
            await viewModel.run(meetingId: meetingId, audioURL: audioURL)
            await onSpeakersChanged()
            await loadSuggestions()
        }
    }

    private func loadSuggestions() async {
        guard case let .succeeded(result) = viewModel.runState else { return }
        for speaker in result.speakers where speaker.tier != .autoConfirm {
            suggestionsBySpeaker[speaker.speakerId] = await viewModel.assignmentSuggestions(for: speaker.speakerId)
        }
    }
}

/// The "Assign person…" picker: ranked suggestions (plan §6, parity-M3) above the full
/// assignable-person list, plus "New person…". Selecting a row is the only write trigger — the
/// caller's `onSelect` performs the actual confirm.
private struct AssignPersonSheet: View {
    let people: [Person]
    let suggestions: [(personId: PersonID, name: String, score: Float)]
    let createPerson: (String) async -> PersonID
    let onSelect: (PersonID) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var newPersonName: String = ""

    var body: some View {
        NavigationStack {
            List {
                if !suggestions.isEmpty {
                    Section("Suggested") {
                        ForEach(suggestions, id: \.personId) { suggestion in
                            Button {
                                onSelect(suggestion.personId)
                            } label: {
                                CardRow(
                                    title: suggestion.name,
                                    metadata: "\(Int((suggestion.score * 100).rounded()))% match"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("All people") {
                    ForEach(people) { person in
                        Button {
                            onSelect(person.id)
                        } label: {
                            CardRow(title: person.displayName)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("New person") {
                    HStack(spacing: MarginaliaSpacing.sm.value) {
                        MarginaliaTextField(text: $newPersonName, prompt: "Name", scheme: scheme)
                        Button("Add") {
                            let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            Task {
                                let personId = await createPerson(name)
                                onSelect(personId)
                            }
                        }
                        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                        .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.marginalia(.canvas, in: scheme))
            .navigationTitle("Assign person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }
}
