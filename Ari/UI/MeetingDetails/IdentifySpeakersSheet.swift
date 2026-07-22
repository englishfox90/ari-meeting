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
    /// Play the clip from its start; the second argument is the clip's known end (`nil` if
    /// unknown) — clip-bounded playback (`AudioPlayerController.playClip`).
    let onPlayClip: (Double, Double?) -> Void

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
            .navigationTitle("Identify speakers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            }
            // Pushed, not a nested `.sheet` (liquid-glass-adoption.md rule 45: stock
            // presentation, zero custom backgrounds, and no modal-on-modal) — a `NavigationStack`
            // already wraps this content, so "Assign person" pushes onto it. The Back affordance
            // comes from the stack for free; confirming pops back to the results list by clearing
            // `assignSpeakerId`, the same signal that drove the old sheet's dismissal.
            .navigationDestination(item: $assignSpeakerId) { speakerId in
                AssignPersonView(
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
                    }
                )
            }
        }
        // Widened for the two-column assign destination (Evidence ~55% | suggestions/people/new).
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await viewModel.loadHint(for: meetingId)
            await viewModel.loadAssignablePeople()
            if countText.isEmpty, case let .upperBound(n) = viewModel.prefilledHint?.hint {
                countText = String(n)
                viewModel.setUncertainCount(n)
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
                    Text("\(result.unresolvedRows) transcript \(result.unresolvedRows == 1 ? "row" : "rows") could not be matched to a speaker.")
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

    /// D9b review fix: mark a speaker row confirmed after the `AssignPersonView` flow, so it
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

/// The "Assign person…" destination — pushed onto the enclosing `NavigationStack`, not a nested
/// modal (liquid-glass-adoption.md rule 45). Two scrollable columns, no painted background (the
/// system sheet supplies the glass): **Evidence** (left, ~55% width — the full, up-to-5-line
/// identification evidence, unlike the compact rows in the results list, mirroring the
/// Rust/React `SpeakerAssignDialog` passing no `limit` prop) and, on the right, ranked
/// suggestions (when present) above the full assignable-person list, then "New person…".
/// Selecting a row is the only write trigger — the caller's `onSelect` performs the actual
/// confirm and pops the stack.
private struct AssignPersonView: View {
    let people: [Person]
    let suggestions: [(personId: PersonID, name: String, score: Float)]
    let samples: [SpeakerSamples.SpeakerSample]
    let audioAvailable: Bool
    let isPlaying: Bool
    let onPlayClip: (Double, Double?) -> Void
    let createPerson: (String) async throws -> PersonID
    let onSelect: (PersonID) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var newPersonName: String = ""
    /// Honest failure surface (D9b review fix) — a failed `createPerson` shows here instead of
    /// silently dropping the user's typed name with no explanation.
    @State private var createPersonError: String?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                evidenceColumn
                    .frame(width: geometry.size.width * 0.55, alignment: .topLeading)
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                peopleColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle("Assign person")
    }

    private var evidenceColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                SectionHeader(title: "Evidence")
                if samples.isEmpty {
                    // No-Fake-State: honest, not a fabricated "no evidence yet" implying evidence
                    // is coming.
                    Text("No transcribed lines available for this speaker.")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                } else {
                    SpeakerSampleList(
                        samples: samples,
                        audioAvailable: audioAvailable,
                        isPlaying: isPlaying,
                        onPlayClip: onPlayClip
                    )
                }
            }
            .padding(MarginaliaSpacing.md.value)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var peopleColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                        SectionHeader(title: "Looks like…")
                        pickerList(suggestions.map { suggestion in
                            (id: suggestion.personId, title: suggestion.name, metadata: "\(Int((suggestion.score * 100).rounded()))% match")
                        })
                    }
                }
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    SectionHeader(title: "All people")
                    if people.isEmpty {
                        Text("No people yet — add one below.")
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    } else {
                        pickerList(people.map { (id: $0.id, title: $0.displayName, metadata: nil) })
                    }
                }
                VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                    SectionHeader(title: "New person")
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
            .padding(MarginaliaSpacing.md.value)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A flat, tappable list of picker rows sharing one hairline-divided layout — used for both
    /// the "Looks like…" suggestions and "All people".
    private func pickerList(_ rows: [(id: PersonID, title: String, metadata: String?)]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.id) { row in
                Button {
                    onSelect(row.id)
                } label: {
                    CardRow(title: row.title, metadata: row.metadata)
                }
                .buttonStyle(.plain)
                if row.id != rows.last?.id {
                    Divider().overlay(Color.marginalia(.hairline, in: scheme))
                }
            }
        }
    }
}
