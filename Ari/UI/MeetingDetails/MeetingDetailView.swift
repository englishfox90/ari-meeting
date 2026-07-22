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
import OSLog
import SwiftUI

struct MeetingDetailView: View {
    private static let uiLog = Logger(subsystem: "com.arivo.ari", category: "diarization-ui")
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
    @State private var seriesViewModel: AddToSeriesViewModel
    /// Drives the "Add to series" popover in the meeting header (← the old app's series affordance).
    @State private var showingSeriesPicker = false
    /// The pending title for the "Create new series" field, pre-filled with the meeting title when
    /// the popover opens.
    @State private var newSeriesTitle = ""
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
    /// Constructed lazily the first time it's needed (in `.task`, or a manual-action tap as a
    /// fallback) — the app composition root's `summaryRunner` (docs/plans/
    /// swift-meeting-generation-flow.md, Track 1) isn't available until `AppEnvironment.bootstrap()`
    /// finishes. Mirrors `speakerIdentificationViewModel`'s lazy-build shape immediately above.
    @State private var summaryViewModel: MeetingSummaryViewModel?
    /// Drives the "Instructions" popover in the summary actions bar (← the old app's custom-
    /// instruction control). The text itself lives on `summaryViewModel.customInstructions`.
    @State private var showingInstructions = false
    /// Item-driven sheet context: presenting via `.sheet(item:)` builds the content from THIS
    /// value, so it can never see a stale nil view model. Presenting with `isPresented:` after
    /// writing the VM in the same transaction rendered the sheet against the pre-write state
    /// snapshot — the "Speaker identification isn't available" fallback on a healthy meeting.
    @State private var identifyContext: IdentifySpeakersContext?

    private struct IdentifySpeakersContext: Identifiable {
        let id = UUID()
        let viewModel: SpeakerIdentificationViewModel
        let audioURL: URL
    }
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, meetingId: MeetingID, initialSeek: Double? = nil) {
        self.database = database
        self.meetingId = meetingId
        self.initialSeek = initialSeek
        _viewModel = State(initialValue: MeetingDetailViewModel(database: database))
        _seriesViewModel = State(initialValue: AddToSeriesViewModel(database: database))
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
            await seriesViewModel.load(meetingId: meetingId)
            // Load templates + restore the picker's selection from whatever summary just
            // resolved (docs/plans/swift-meeting-generation-flow.md, Track 1) — honest: reflects
            // the summary actually on screen, never a fabricated default selection.
            if let summaryVM = summaryViewModelIfAvailable() {
                // Reset first: the detail view is REUSED across meetings in the split detail
                // column (same `@State` view model), so a `.failed`/`.generating` state from the
                // previously-shown meeting must be cleared before this one renders (No-Fake-State).
                summaryVM.reset()
                summaryVM.loadTemplates()
                summaryVM.restoreSelection(from: viewModel.summary)
            }
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
        // docs/plans/swift-meeting-generation-flow.md, Track 2: when the post-recording pipeline
        // finishes THIS meeting, pull in whatever it produced (speaker labels, summary) — the
        // pipeline itself already persisted via the same repositories this view reads through.
        .onChange(of: environment.processingCoordinator?.phase) { _, newPhase in
            guard case .completed = newPhase,
                  environment.processingCoordinator?.activeMeetingID == meetingId else { return }
            Task {
                await viewModel.load(meetingId)
                summaryViewModelIfAvailable()?.restoreSelection(from: viewModel.summary)
            }
        }
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
            processingBanner
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
            seriesAffordance
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Add to series (← the old app's meeting-header series affordance)

    /// The current-series chips (removable) plus the button that opens the add/create popover.
    /// When the meeting is in no series, this is just a quiet "Add to series" button — nothing is
    /// implied about membership that isn't real (No-Fake-State).
    private var seriesAffordance: some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            ForEach(seriesViewModel.currentSeries) { series in
                seriesChip(series)
            }
            Button {
                newSeriesTitle = viewModel.meeting.value?.title ?? ""
                showingSeriesPicker = true
            } label: {
                Label(
                    seriesViewModel.currentSeries.isEmpty ? "Add to series" : "Add to another series",
                    systemImage: "plus"
                )
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            .popover(isPresented: $showingSeriesPicker, arrowEdge: .bottom) {
                seriesPickerContent
            }
        }
        .padding(.top, MarginaliaSpacing.xs.value)
    }

    private func seriesChip(_ series: SeriesSummary) -> some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            Text(series.title)
                .marginaliaTextStyle(.callout, in: scheme)
            Button {
                Task { await seriesViewModel.remove(seriesId: series.id, meetingId: meetingId) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            .help("Remove from “\(series.title)”")
        }
        .padding(.horizontal, MarginaliaSpacing.sm.value)
        .padding(.vertical, MarginaliaSpacing.xs.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                .fill(Color.marginalia(.elevated, in: scheme))
        }
    }

    private var seriesPickerContent: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            MarginaliaSearchField(
                text: seriesSearchBinding,
                prompt: "Search series…",
                scheme: scheme,
                size: .compact
            )
            if !seriesViewModel.filteredSeries.isEmpty {
                Text("Existing series")
                    .marginaliaTextStyle(.caption, in: scheme)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(seriesViewModel.filteredSeries) { series in
                            Button {
                                Task {
                                    await seriesViewModel.addToExisting(seriesId: series.id, meetingId: meetingId)
                                    if seriesViewModel.errorMessage == nil { showingSeriesPicker = false }
                                }
                            } label: {
                                HStack {
                                    Text(series.title)
                                        .marginaliaTextStyle(.body, in: scheme)
                                    Spacer(minLength: MarginaliaSpacing.md.value)
                                    Text(meetingCountLabel(series.meetingCount))
                                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, MarginaliaSpacing.xs.value)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Divider().overlay(Color.marginalia(.hairline, in: scheme))
            Text("Create new series")
                .marginaliaTextStyle(.caption, in: scheme)
            HStack(spacing: MarginaliaSpacing.sm.value) {
                MarginaliaTextField(text: $newSeriesTitle, prompt: "New series name", scheme: scheme)
                Button("Create") {
                    Task {
                        await seriesViewModel.createAndAdd(title: newSeriesTitle, meetingId: meetingId)
                        if seriesViewModel.errorMessage == nil { showingSeriesPicker = false }
                    }
                }
                .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                .disabled(newSeriesTitle.trimmingCharacters(in: .whitespaces).isEmpty || seriesViewModel.isBusy)
            }
            if let error = seriesViewModel.errorMessage {
                Text(error)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .error)
            }
        }
        .padding(MarginaliaSpacing.md.value)
        .frame(width: 340)
    }

    private var seriesSearchBinding: Binding<String> {
        Binding(
            get: { seriesViewModel.searchText },
            set: { seriesViewModel.searchText = $0 }
        )
    }

    private func meetingCountLabel(_ count: Int) -> String {
        count == 1 ? "1 meeting" : "\(count) meetings"
    }

    @ViewBuilder
    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            if let summary = viewModel.summary {
                MarginaliaMarkdownView(markdown: summary.bodyMarkdown, onSeek: seekHandler)
            } else {
                emptyState(
                    title: "No summary yet",
                    message: "A summary hasn't been generated for this meeting."
                )
            }
            summaryActionsBar
        }
    }

    // MARK: - Processing banner (docs/plans/swift-meeting-generation-flow.md, Track 2)

    /// The post-recording pipeline's live status for THIS meeting — rendered only while
    /// `processingCoordinator` is actively tracking it. Every message reflects a real
    /// `MeetingProcessingCoordinator.Phase`/`diarizationNote` (No-Fake-State): once the pipeline
    /// reaches `.completed` with no note, the banner disappears entirely — the freshly reloaded
    /// summary above already speaks for itself, so there is nothing honest left to say.
    @ViewBuilder
    private var processingBanner: some View {
        if let coordinator = environment.processingCoordinator, coordinator.activeMeetingID == meetingId,
           let message = processingBannerMessage(coordinator) {
            MarginaliaBanner(kind: processingBannerKind(coordinator.phase), message: message, scheme: scheme)
        }
    }

    private func processingBannerMessage(_ coordinator: MeetingProcessingCoordinator) -> String? {
        switch coordinator.phase {
        case .identifyingSpeakers:
            "Identifying speakers…"
        case .needsSpeakerCount:
            "Waiting for a speaker count to continue — see the prompt."
        case .selectingTemplate:
            "Choosing a template…"
        case .summarizing:
            "Generating summary…"
        case .completed:
            // The only honest thing left to say once complete: a non-fatal diarization note, if
            // one was recorded (decision 3) — otherwise nothing (the reloaded summary above is
            // the real signal that processing finished).
            coordinator.diarizationNote
        case let .failed(message):
            message
        case .idle:
            nil
        }
    }

    private func processingBannerKind(_ phase: MeetingProcessingCoordinator.Phase) -> MarginaliaBannerKind {
        if case .failed = phase { return .error }
        return .info
    }

    /// Whether the pipeline is actively working on THIS meeting (mirrors Rust's
    /// `isBackgroundProcessing` gate) — used to disable the Track-1 manual summary actions below
    /// so a manual generate never races the pipeline's own auto-generate for the same meeting.
    private var isCoordinatorProcessingThisMeeting: Bool {
        guard let coordinator = environment.processingCoordinator, coordinator.activeMeetingID == meetingId else {
            return false
        }
        switch coordinator.phase {
        case .identifyingSpeakers, .selectingTemplate, .summarizing:
            return true
        case .idle, .needsSpeakerCount, .completed, .failed:
            return false
        }
    }

    // MARK: - Summary actions (docs/plans/swift-meeting-generation-flow.md, Track 1)

    /// Generate / Regenerate / change-template / Cancel — rendered only once `summaryViewModel`
    /// resolves (via `.task`'s lazy build), so this never shows a dead-looking control while
    /// `AppEnvironment.bootstrap()` is still constructing `summaryRunner` (No-Fake-State). Reads
    /// `summaryViewModel` directly (never mutates `@State` from inside body construction — the
    /// lazy build itself only ever runs from `.task` or a button's own action closure, mirroring
    /// `speakerIdentificationViewModel`'s discipline).
    @ViewBuilder
    private var summaryActionsBar: some View {
        if let summaryVM = summaryViewModel {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                HStack(spacing: MarginaliaSpacing.sm.value) {
                    Picker(selection: templateSelectionBinding(summaryVM)) {
                        Text("Auto (suggest)").tag(nil as String?)
                        ForEach(summaryVM.templates) { option in
                            Text(option.name).tag(option.id as String?)
                        }
                    } label: {
                        MarginaliaMenuLabel(title: "Template", scheme: scheme)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(minWidth: 160)
                    .disabled(isSummaryGenerating(summaryVM) || isCoordinatorProcessingThisMeeting)

                    instructionsControl(summaryVM)

                    if viewModel.summary != nil {
                        Button("Regenerate") {
                            generateSummary()
                        }
                        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                        .disabled(isSummaryGenerating(summaryVM) || isCoordinatorProcessingThisMeeting)
                    } else {
                        Button("Generate summary") {
                            generateSummary()
                        }
                        .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                        .disabled(isSummaryGenerating(summaryVM) || isCoordinatorProcessingThisMeeting)
                    }

                    if isSummaryGenerating(summaryVM) {
                        Button("Cancel") {
                            Task { await summaryVM.cancel(meetingId: meetingId) }
                        }
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                    }
                }
                if isSummaryGenerating(summaryVM) {
                    Text("Generating summary…")
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
                // Honest failure line (No-Fake-State): the prior summary above is untouched —
                // this VM carries no summary state of its own to clobber.
                if case let .failed(message) = summaryVM.state {
                    Text(message)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .error)
                }
            }
        }
    }

    private func isSummaryGenerating(_ summaryVM: MeetingSummaryViewModel) -> Bool {
        if case .generating = summaryVM.state { return true }
        return false
    }

    private func templateSelectionBinding(_ summaryVM: MeetingSummaryViewModel) -> Binding<String?> {
        Binding(
            get: { summaryVM.selectedTemplateID },
            set: { summaryVM.selectedTemplateID = $0 }
        )
    }

    /// The "Instructions" control (← the old app's custom-instruction toolbar button): a button
    /// that opens a popover with a themed multi-line editor bound to
    /// `summaryVM.customInstructions`. A filled `pencil` glyph honestly signals when steering text
    /// is actually present (No-Fake-State) — nothing is implied when the field is empty. The text
    /// is injected into the summary prompt only on the next Generate/Regenerate.
    @ViewBuilder
    private func instructionsControl(_ summaryVM: MeetingSummaryViewModel) -> some View {
        let hasInstructions = !summaryVM.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button {
            showingInstructions = true
        } label: {
            Label("Instructions", systemImage: hasInstructions ? "pencil.circle.fill" : "pencil")
        }
        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
        .disabled(isSummaryGenerating(summaryVM) || isCoordinatorProcessingThisMeeting)
        .help("Add custom instructions to steer the summary")
        .popover(isPresented: $showingInstructions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                Text("Instructions")
                    .marginaliaTextStyle(.caption, in: scheme)
                Text("Extra context or steering added to the summary prompt. Applied on the next Generate or Regenerate.")
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                MarginaliaTextEditor(
                    text: instructionsBinding(summaryVM),
                    prompt: "e.g. Focus on decisions and blockers; keep it concise.",
                    scheme: scheme,
                    minHeight: 96
                )
                .frame(width: 320)
                HStack {
                    Spacer()
                    Button("Clear") {
                        summaryVM.customInstructions = ""
                    }
                    .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                    .disabled(!hasInstructions)
                    Button("Done") {
                        showingInstructions = false
                    }
                    .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                }
            }
            .padding(MarginaliaSpacing.md.value)
        }
    }

    private func instructionsBinding(_ summaryVM: MeetingSummaryViewModel) -> Binding<String> {
        Binding(
            get: { summaryVM.customInstructions },
            set: { summaryVM.customInstructions = $0 }
        )
    }

    /// Lazily builds `MeetingSummaryViewModel` from `environment.summaryRunner`, mirroring
    /// `openIdentifySpeakers()`'s lazy-build pattern below. Returns `nil` (never a dead-looking
    /// control) while bootstrap hasn't finished constructing the runner yet.
    private func summaryViewModelIfAvailable() -> MeetingSummaryViewModel? {
        if summaryViewModel == nil {
            guard let runner = environment.summaryRunner else {
                Self.uiLog.error("summary actions: summaryRunner unavailable; not building view model")
                return nil
            }
            summaryViewModel = MeetingSummaryViewModel(runner: runner)
        }
        return summaryViewModel
    }

    /// Real speaker signal for the auto-template classifier (← plan: "`speakerCount` arg =
    /// `viewModel.speakerNames.count` (real signal) or nil") — an honest `nil` when nothing has
    /// resolved yet, never a fabricated `0`.
    private func generateSummary() {
        guard let summaryVM = summaryViewModelIfAvailable() else { return }
        let targetMeetingId = meetingId
        let speakerCount = viewModel.speakerNames.isEmpty ? nil : viewModel.speakerNames.count
        Task {
            guard await summaryVM.generate(meetingId: targetMeetingId, speakerCount: speakerCount) != nil else { return }
            // Only fold the result back in if the shared detail view still shows the meeting we
            // generated for. Generation is long-running and the `viewModel`/`summaryVM` are a
            // single `@State` pair reused across the split detail column, so if the user has
            // since selected another meeting, ITS own `.task(id:)` owns the reload — folding this
            // meeting's summary in here would bleed it under the other meeting's title
            // (No-Fake-State). The generation itself is never cancelled by the switch; only this
            // stale reload is skipped.
            guard viewModel.meeting.value?.id == targetMeetingId else { return }
            await viewModel.load(targetMeetingId)
            summaryVM.restoreSelection(from: viewModel.summary)
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
            HStack(spacing: MarginaliaSpacing.sm.value) {
                if !canIdentifySpeakers {
                    // Honest disabled state (plan §6): the reason must be visible, not
                    // hover-only — a silently inert button reads as broken.
                    Text(identifySpeakersShortReason)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                }
                Button {
                    openIdentifySpeakers()
                } label: {
                    Label("Identify speakers", systemImage: "person.crop.circle")
                }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                .disabled(!canIdentifySpeakers)
                .help(canIdentifySpeakers ? "Identify speakers in this recording" : identifySpeakersDisabledReason)
            }
            .sheet(item: $identifyContext) { context in
                identifySpeakersSheet(context)
            }
        }
    }

    /// Compact inline form of `identifySpeakersDisabledReason` — the full detail (including
    /// the missing path) stays in the tooltip and the audio banner.
    private var identifySpeakersShortReason: String {
        if case .missing = viewModel.audio { return "Needs an audio file" }
        return "Needs audio-timed transcript"
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
        Self.uiLog.info("""
        identify-speakers click: audio=\(String(describing: viewModel.audio), privacy: .public), \
        timedSegments=\(viewModel.transcript.filter { $0.audioStartTime != nil }.count), \
        service=\(environment.diarizationService == nil ? "nil" : "ok", privacy: .public), \
        hintProvider=\(environment.speakerCountHintProvider == nil ? "nil" : "ok", privacy: .public), \
        vmCached=\(speakerIdentificationViewModel != nil)
        """)
        if speakerIdentificationViewModel == nil,
           let service = environment.diarizationService,
           let hintProvider = environment.speakerCountHintProvider {
            speakerIdentificationViewModel = SpeakerIdentificationViewModel(
                service: service,
                hintProvider: hintProvider,
                isRecording: { environment.recordingSession?.isActive ?? false }
            )
        }
        guard let vm = speakerIdentificationViewModel else {
            // No service/hint provider (bootstrap incomplete or failed) — never present a
            // dead sheet; the button click is a no-op with a log trail.
            Self.uiLog.error("identify-speakers: view model unavailable; not presenting sheet")
            return
        }
        guard case let .available(url) = viewModel.audio else {
            Self.uiLog.error("identify-speakers: audio not available at click; not presenting")
            return
        }
        identifyContext = IdentifySpeakersContext(viewModel: vm, audioURL: url)
    }

    private func identifySpeakersSheet(_ context: IdentifySpeakersContext) -> some View {
        IdentifySpeakersSheet(
                viewModel: context.viewModel,
                meetingId: meetingId,
                audioURL: context.audioURL,
                displayName: viewModel.displayName(for:),
                createPerson: { name in
                    // D9b review fix: surface the upsert failure instead of swallowing it with
                    // `try?` and returning a dangling `PersonID` — with FKs ON, a dangling id
                    // would later throw a raw FK error out of `confirmSpeaker` into
                    // `runState.failed`, wiping the results list with no honest explanation.
                    let person = Person(
                        id: PersonID(UUID().uuidString),
                        displayName: name,
                        isOwner: false,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                    try await database.persons.upsert(person)
                    return person.id
                },
                onSpeakersChanged: { await viewModel.load(meetingId) },
                onDismiss: { identifyContext = nil },
                samplesFor: { speakerId in
                    SpeakerSamples.select(from: viewModel.transcript, speakerId: speakerId)
                },
                audioAvailable: {
                    if case .available = viewModel.audio { return true }
                    return false
                }(),
                isPlaying: audioController.isPlaying,
                onPlayClip: { start, end in
                    audioController.playClip(fromSeconds: start, toSeconds: end)
                }
            )
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
