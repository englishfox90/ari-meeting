//
//  MeetingDetailView.swift — the saved-meeting reading view.
//
//  Two-pane on a wide window (the summary leads in the primary column; the Listen Back
//  transport, source-record provenance, and transcript live in a right rail), collapsing to a
//  single stacked column with a section switcher when the window is narrow. The summary — the
//  valuable, at-a-glance content — is what greets you, not a wall of transcript.
//
//  Rich summary rendering goes through `MarginaliaMarkdownView` (headings/lists/table), not the
//  flattened inline `MarkdownText`. Referenced-moments chips, the scrubber, and the provenance
//  block all render real data only, and are omitted (never faked) when the data is absent.
//
import AriKit
import AriViewModels
import SwiftUI

struct MeetingDetailView: View {
    let database: AppDatabase
    let meetingId: MeetingID
    /// When opened from a cross-meeting citation, the scrubber positions here once audio loads.
    var initialSeek: Double?

    /// Below this detail-column width the two panes stack into one scrolling column with a
    /// section switcher (a right rail can't earn its keep on a narrow window). 800 = the
    /// design's own floor (minSummaryWidth 480 + minRailWidth 300 + divider) — the previous
    /// 860 left the DEFAULT window size (~865pt detail column) on a knife edge that collapsed
    /// to narrow mode with any extra chrome.
    private static let twoPaneMinWidth: CGFloat = 800
    private static let defaultRailWidth: CGFloat = 380
    private static let minRailWidth: CGFloat = 300
    /// The summary column keeps at least this much width — the rail can't be dragged wider than
    /// (total − this).
    private static let minSummaryWidth: CGFloat = 480

    @State private var viewModel: MeetingDetailViewModel
    @State private var audioController = AudioPlayerController()
    @State private var narrowSection: NarrowSection = .summary
    @State private var isNarrowLayout = false
    @State private var railWidth: CGFloat = MeetingDetailView.defaultRailWidth
    /// The rail width captured at the start of a divider drag, so each `onChanged` computes from a
    /// fixed base instead of compounding — the compounding + live relayout is what made the seam
    /// jitter between states.
    @State private var railWidthAtDragStart: CGFloat?
    /// Constructed lazily the first time "Identify speakers" is opened — the app composition
    /// root's `diarizationService`/`speakerCountHintProvider` (docs/plans/arikit-diarization.md
    /// §5 D9b) aren't available until `AppEnvironment.bootstrap()` finishes.
    @State private var speakerIdentificationViewModel: SpeakerIdentificationViewModel?
    @State private var showIdentifySpeakers = false
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, meetingId: MeetingID, initialSeek: Double? = nil) {
        self.database = database
        self.meetingId = meetingId
        self.initialSeek = initialSeek
        _viewModel = State(initialValue: MeetingDetailViewModel(database: database))
    }

    private enum NarrowSection: String, CaseIterable, Identifiable {
        case summary, transcript, notes
        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .summary: "Summary"
            case .transcript: "Transcript"
            case .notes: "Notes"
            }
        }
    }

    var body: some View {
        StateContainer(state: viewModel.meeting, emptyTitle: "No meeting", emptyMessage: nil) { meeting in
            GeometryReader { geometry in
                if geometry.size.width >= Self.twoPaneMinWidth {
                    twoPane(meeting, totalWidth: geometry.size.width)
                } else {
                    narrowColumn(meeting)
                }
            }
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width < Self.twoPaneMinWidth
            } action: { narrow in
                isNarrowLayout = narrow
            }
        }
        .background(MarginaliaCanvasWash(scheme: scheme))
        // The section switcher lives in the TOOLBAR in narrow mode — the toolbar is the
        // system's Liquid Glass layer on macOS 26, so the segmented switcher renders in the
        // floating glass grouping there (the Finder/Notes/Music view-switcher idiom). An
        // embedded, mid-content tab bar draws the compact flat control instead — that's why
        // the in-content attempts never looked like glass.
        .toolbar {
            if isNarrowLayout {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $narrowSection) {
                        ForEach(NarrowSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
        .navigationTitle(viewModel.meeting.value?.title ?? "Meeting")
        .task(id: meetingId) {
            // Reset first: the detail view is REUSED across meetings in the split detail column
            // (no per-meeting `.id`), so a previous meeting's player must be stopped before the
            // new one loads — otherwise selecting a meeting with missing/absent audio would leave
            // the prior meeting audible with no visible transport to stop it.
            audioController.reset()
            narrowSection = .summary
            await viewModel.load(meetingId)
            if case let .available(url) = viewModel.audio {
                audioController.load(url: url)
                // Opened from a cross-meeting citation → position at the cited moment. Positions
                // only; playback stays paused so audio never starts unbidden.
                if let initialSeek {
                    audioController.seek(toSeconds: initialSeek)
                }
            }
        }
        .onDisappear { audioController.reset() }
    }

    // MARK: - Wide: two-pane

    private func twoPane(_ meeting: Meeting, totalWidth: CGFloat) -> some View {
        let maxRail = max(Self.minRailWidth, totalWidth - Self.minSummaryWidth)
        let effectiveRail = min(max(railWidth, Self.minRailWidth), maxRail)
        return HStack(spacing: 0) {
            ScrollView {
                summaryColumn(meeting, showInlineNotes: true)
                    .padding(MarginaliaSpacing.xl.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            resizableDivider(maxRail: maxRail)

            rightRail(meeting)
                .frame(width: effectiveRail)
                .background(Color.marginalia(.elevated, in: scheme))
        }
    }

    /// The draggable seam between the summary and the rail. Dragging left widens the rail;
    /// clamped so neither side collapses. Translation is read in GLOBAL space and applied to a
    /// drag-start base width — local translation feeds the live relayout back into the gesture's
    /// own moving origin, which is what made the seam shake.
    private func resizableDivider(maxRail: CGFloat) -> some View {
        Divider()
            .overlay(Color.marginalia(.hairline, in: scheme))
            .frame(maxHeight: .infinity)
            .padding(.horizontal, MarginaliaSpacing.xs.value)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let base = railWidthAtDragStart ?? railWidth
                        if railWidthAtDragStart == nil {
                            railWidthAtDragStart = base
                        }
                        railWidth = min(max(base - value.translation.width, Self.minRailWidth), maxRail)
                    }
                    .onEnded { _ in railWidthAtDragStart = nil }
            )
    }

    private func rightRail(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            missingAudioNotice
            sourceRecordSection(meeting)
            Divider().overlay(Color.marginalia(.hairline, in: scheme))
            transcriptHeader
            TranscriptListView(
                transcript: viewModel.transcript,
                displayName: viewModel.displayName(for:),
                onSeek: { audioController.seek(toSeconds: $0) }
            )
        }
        // The glass transport floats over the SCROLLING transcript (safeAreaInset) — glass
        // needs content moving beneath it to read as glass; inline on the flat rail it drew
        // as opaque pills (the same chrome-layer lesson as the section switcher).
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            floatingTransport
        }
    }

    // MARK: - Narrow: single stacked column

    /// Narrow mode: content switched by the TOOLBAR section picker (see `body`'s `.toolbar`)
    /// — the switcher itself lives in the window's glass layer, not in the content column.
    private func narrowColumn(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            missingAudioNotice
            switch narrowSection {
            case .summary:
                ScrollView {
                    // Notes have their own tab in narrow mode, so don't also fold them into
                    // Summary.
                    summaryColumn(meeting, showInlineNotes: false)
                        .padding(MarginaliaSpacing.md.value)
                }
            case .transcript:
                VStack(spacing: 0) {
                    transcriptHeader
                    TranscriptListView(
                        transcript: viewModel.transcript,
                        displayName: viewModel.displayName(for:),
                        onSeek: { audioController.seek(toSeconds: $0) }
                    )
                }
            case .notes:
                notesBody
            }
        }
        // Same chrome-layer rule as the wide rail: the transport floats over the scrolling
        // section content, never inline as an opaque band.
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            floatingTransport
        }
    }

    // MARK: - Shared building blocks

    private func summaryColumn(_ meeting: Meeting, showInlineNotes: Bool) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xl.value) {
            header(meeting)
            // The moment chips are a "play" affordance — only offer them when there's actually
            // resolvable audio to seek. The inline `[MM:SS]` markers still read as text otherwise.
            if let seek = seekHandler, !viewModel.referencedMoments.isEmpty {
                ReferencedMomentsBar(moments: viewModel.referencedMoments, onSeek: seek)
            }
            summaryBody
            if showInlineNotes {
                notesInlineSection
            }
        }
    }

    /// A seek closure only when audio is resolvable — otherwise `nil`, so citation chips and the
    /// inline markdown badges render inert instead of as dead "play" controls (No-Fake-State).
    private var seekHandler: ((Double) -> Void)? {
        guard case .available = viewModel.audio else { return nil }
        return { audioController.seek(toSeconds: $0) }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text("Meeting note")
                .marginaliaTextStyle(.caption, in: scheme)
            Text(meeting.title)
                .marginaliaTextStyle(.title1, in: scheme, ink: .inkHeading)
            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var summaryBody: some View {
        if let summary = viewModel.summary {
            MarginaliaMarkdownView(markdown: summary.bodyMarkdown, onSeek: seekHandler)
        } else {
            emptyState(
                title: "No summary yet",
                message: "A summary hasn't been generated for this meeting."
            )
        }
    }

    /// The notes block folded into the bottom of the summary column — only when notes exist.
    @ViewBuilder
    private var notesInlineSection: some View {
        if let markdown = viewModel.notes?.notesMarkdown, !markdown.isEmpty {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                Text("Notes")
                    .marginaliaTextStyle(.caption, in: scheme)
                MarginaliaMarkdownView(markdown: markdown)
            }
        }
    }

    @ViewBuilder
    private var notesBody: some View {
        if let markdown = viewModel.notes?.notesMarkdown, !markdown.isEmpty {
            ScrollView {
                MarginaliaMarkdownView(markdown: markdown)
                    .padding(MarginaliaSpacing.md.value)
            }
        } else {
            emptyState(title: "No notes", message: "Nothing has been written for this meeting yet.")
        }
    }

    /// The floating glass transport — rendered only when audio genuinely resolved, placed by
    /// callers in a bottom `safeAreaInset` so content scrolls beneath the glass.
    @ViewBuilder
    private var floatingTransport: some View {
        if viewModel.meeting.value?.audioReference != nil, case .available = viewModel.audio {
            ListenBackPanel(controller: audioController)
        }
    }

    /// The honest missing-file reason — an inline, opaque content-layer status note (never
    /// floating glass). Reserved for a REAL `audioReference` that didn't resolve; a `nil`
    /// reference renders nothing (there's no recording to miss).
    @ViewBuilder
    private var missingAudioNotice: some View {
        if viewModel.meeting.value?.audioReference != nil, case let .missing(reason) = viewModel.audio {
            Text(reason)
                .marginaliaTextStyle(.caption, in: scheme)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MarginaliaSpacing.md.value)
        }
    }

    private func sourceRecordSection(_ meeting: Meeting) -> some View {
        SourceRecordPanel(
            meeting: meeting,
            summary: viewModel.summary,
            segmentCount: viewModel.transcript.count
        )
    }

    private var transcriptHeader: some View {
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Text("Transcript")
                .marginaliaTextStyle(.caption, in: scheme)
            if !viewModel.transcript.isEmpty {
                Text("\(viewModel.transcript.count) segments")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }
            Spacer()
            identifySpeakersButton
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.top, MarginaliaSpacing.md.value)
    }

    /// "Identify speakers" entry point (plan §6) — visible whenever the meeting has a recording
    /// at all, disabled with an honest reason (never silently hidden) until real audio and
    /// audio-timed transcript rows both resolve.
    @ViewBuilder
    private var identifySpeakersButton: some View {
        if viewModel.meeting.value?.audioReference != nil {
            Button {
                openIdentifySpeakers()
            } label: {
                Label("Identify speakers", systemImage: "person.crop.circle")
            }
            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
            .disabled(!canIdentifySpeakers)
            .help(canIdentifySpeakers ? "Identify speakers in this recording" : identifySpeakersDisabledReason)
            .sheet(isPresented: $showIdentifySpeakers) {
                identifySpeakersSheet
            }
        }
    }

    private var canIdentifySpeakers: Bool {
        guard case .available = viewModel.audio else { return false }
        return viewModel.transcript.contains { $0.audioStartTime != nil }
    }

    private var identifySpeakersDisabledReason: String {
        if case let .missing(reason) = viewModel.audio { return reason }
        return "No transcript segments with audio timing are available yet."
    }

    private func openIdentifySpeakers() {
        if speakerIdentificationViewModel == nil,
           let service = environment.diarizationService,
           let hintProvider = environment.speakerCountHintProvider {
            speakerIdentificationViewModel = SpeakerIdentificationViewModel(
                service: service,
                hintProvider: hintProvider,
                isRecording: { environment.recordingSession?.isActive ?? false }
            )
        }
        showIdentifySpeakers = true
    }

    @ViewBuilder
    private var identifySpeakersSheet: some View {
        if let speakerIdentificationViewModel, case let .available(url) = viewModel.audio {
            IdentifySpeakersSheet(
                viewModel: speakerIdentificationViewModel,
                meetingId: meetingId,
                audioURL: url,
                displayName: viewModel.displayName(for:),
                createPerson: { name in
                    let person = Person(
                        id: PersonID(UUID().uuidString),
                        displayName: name,
                        isOwner: false,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                    try? await database.persons.upsert(person)
                    return person.id
                },
                onSpeakersChanged: { await viewModel.load(meetingId) },
                onDismiss: { showIdentifySpeakers = false }
            )
        } else {
            // Honest fallback (No-Fake-State): the composition root hasn't finished bootstrapping
            // the diarization service, or audio no longer resolves — never a dead/fake sheet.
            Text("Speaker identification isn't available for this meeting right now.")
                .marginaliaTextStyle(.body, in: scheme)
                .padding(MarginaliaSpacing.lg.value)
        }
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text(title)
                .marginaliaTextStyle(.body, in: scheme)
            Text(message)
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MarginaliaSpacing.lg.value)
    }
}
