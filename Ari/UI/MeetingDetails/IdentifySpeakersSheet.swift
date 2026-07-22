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
    /// Throwing (D9b review fix): a failed `PersonRepository.upsert` must surface to the user,
    /// not silently hand back a dangling `PersonID` that later fails an FK constraint deep in
    /// `confirmSpeaker`.
    let createPerson: (String) async throws -> PersonID
    let onSpeakersChanged: () async -> Void
    let onDismiss: () -> Void
    /// The identification evidence for a speaker — real transcribed lines at real timestamps
    /// (`SpeakerSamples.select`), read live from `MeetingDetailViewModel.transcript` so a
    /// completed run's freshly stamped rows show up without re-opening the sheet.
    let samplesFor: (SpeakerID) -> [SpeakerSamples.SpeakerSample]
    /// Whether a playable recording exists — mirrors `SpeakerSampleList`'s honest disabled state.
    let audioAvailable: Bool
    /// Whether the shared meeting player is currently playing (drives the active-clip highlight).
    let isPlaying: Bool
    /// Seek the meeting audio to `seconds` and start playing that moment.
    let onPlayClip: (Double) -> Void

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
    /// D9b review fix: `result.speakers` is a static snapshot from the run — without this, a
    /// just-confirmed speaker keeps rendering as Unidentified/suggest and can be re-confirmed.
    /// Set on a successful confirm; the row overrides its tier-derived label/actions when present.
    @State private var confirmedSpeakerNames: [SpeakerID: String] = [:]

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
                    samples: samplesFor(speakerId),
                    audioAvailable: audioAvailable,
                    isPlaying: isPlaying,
                    onPlayClip: onPlayClip,
                    createPerson: createPerson,
                    onSelect: { personId in
                        Task {
                            await viewModel.confirm(speakerId, as: personId, inMeeting: meetingId)
                            await viewModel.loadAssignablePeople()
                            await onSpeakersChanged()
                            markConfirmed(speakerId, personId: personId)
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

    /// D9b review fix (H2 stale-hint failure mode): an empty or unparseable field must clear
    /// `userHint` rather than no-op — otherwise a previously typed "3" (Exactly) survives after
    /// the field is cleared or the mode is switched to "Not sure", and `run` silently uses the
    /// stale `.exact(3)` while the UI shows an empty/uncertain field.
    private func applyCount(_ text: String) {
        guard let n = Int(text) else {
            viewModel.clearUserHint()
            return
        }
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
                        VStack(alignment: .leading, spacing: 0) {
                            SpeakerAssignmentRow(
                                resolved: resolved,
                                resolvedName: resolved.tier == .autoConfirm ? displayName(resolved.speakerId) : nil,
                                suggestion: topSuggestion(for: resolved.speakerId),
                                confirmedOverrideName: confirmedSpeakerNames[resolved.speakerId],
                                onConfirmSuggestion: { confirmTopSuggestion(for: resolved.speakerId) },
                                onNotThem: { suggestionsBySpeaker[resolved.speakerId] = [] },
                                onAssign: { assignSpeakerId = resolved.speakerId }
                            )
                            SpeakerSampleList(
                                samples: samplesFor(resolved.speakerId),
                                audioAvailable: audioAvailable,
                                isPlaying: isPlaying,
                                onPlayClip: onPlayClip,
                                limit: 2
                            )
                            .padding(.horizontal, MarginaliaSpacing.md.value)
                            .padding(.bottom, MarginaliaSpacing.sm.value)
                        }
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
            // D9b review fix: reflect the confirm in the results row immediately — the top
            // suggestion's name is already in hand, no extra lookup needed.
            confirmedSpeakerNames[speakerId] = top.name
            suggestionsBySpeaker[speakerId] = []
        }
    }

    /// D9b review fix: mark a speaker row confirmed after the `AssignPersonSheet` flow, so it
    /// stops rendering as Unidentified/re-confirmable. Best-effort name resolution: the freshly
    /// (re)loaded assignable-people list, falling back to the resolved display name once the
    /// caller's `onSpeakersChanged` reload catches up.
    private func markConfirmed(_ speakerId: SpeakerID, personId: PersonID) {
        let name = viewModel.assignablePeople.first(where: { $0.id == personId })?.displayName
            ?? displayName(speakerId)
            ?? "Confirmed"
        confirmedSpeakerNames[speakerId] = name
        suggestionsBySpeaker[speakerId] = []
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
    /// The full (up to 5) identification evidence for the speaker being assigned — no `limit`,
    /// unlike the compact rows in the results list (mirrors the Rust/React `SpeakerAssignDialog`
    /// passing no `limit` prop).
    let samples: [SpeakerSamples.SpeakerSample]
    let audioAvailable: Bool
    let isPlaying: Bool
    let onPlayClip: (Double) -> Void
    let createPerson: (String) async throws -> PersonID
    let onSelect: (PersonID) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var newPersonName: String = ""
    /// Honest failure surface (D9b review fix) — a failed `createPerson` shows here instead of
    /// silently dropping the user's typed name with no explanation.
    @State private var createPersonError: String?

    var body: some View {
        NavigationStack {
            List {
                if !samples.isEmpty {
                    Section("Evidence") {
                        SpeakerSampleList(
                            samples: samples,
                            audioAvailable: audioAvailable,
                            isPlaying: isPlaying,
                            onPlayClip: onPlayClip
                        )
                    }
                }
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
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                        HStack(spacing: MarginaliaSpacing.sm.value) {
                            MarginaliaTextField(text: $newPersonName, prompt: "Name", scheme: scheme)
                            Button("Add") {
                                let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                createPersonError = nil
                                Task {
                                    do {
                                        let personId = try await createPerson(name)
                                        onSelect(personId)
                                    } catch {
                                        createPersonError = "Couldn't create \(name): \(error.localizedDescription)"
                                    }
                                }
                            }
                            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                            .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let createPersonError {
                            Text(createPersonError)
                                .marginaliaTextStyle(.callout, in: scheme, ink: .error)
                        }
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
