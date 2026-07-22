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
    @State private var railWidth: CGFloat = MeetingDetailView.defaultRailWidth
    /// The rail width captured at the start of a divider drag, so each `onChanged` computes from a
    /// fixed base instead of compounding — the compounding + live relayout is what made the seam
    /// jitter between states.
    @State private var railWidthAtDragStart: CGFloat?
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
        }
        .background(MarginaliaCanvasWash(scheme: scheme))
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
            audioSection
            sourceRecordSection(meeting)
            Divider().overlay(Color.marginalia(.hairline, in: scheme))
            transcriptHeader
            TranscriptListView(
                transcript: viewModel.transcript,
                displayName: viewModel.displayName(for:),
                onSeek: { audioController.seek(toSeconds: $0) }
            )
        }
    }

    // MARK: - Narrow: single stacked column

    /// Narrow mode uses the STOCK `TabView` — on macOS 26 it renders the system's floating
    /// Liquid Glass tab bar (the HIG tab-views appearance), which no hand-built switcher
    /// should imitate (owner direction 2026-07-21; Liquid Glass v2 stock-first rule).
    private func narrowColumn(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            audioSection
            TabView(selection: $narrowSection) {
                Tab(NarrowSection.summary.title, systemImage: "doc.text", value: .summary) {
                    ScrollView {
                        // Notes have their own tab in narrow mode, so don't also fold them
                        // into Summary.
                        summaryColumn(meeting, showInlineNotes: false)
                            .padding(MarginaliaSpacing.md.value)
                    }
                }
                Tab(NarrowSection.transcript.title, systemImage: "text.quote", value: .transcript) {
                    TranscriptListView(
                        transcript: viewModel.transcript,
                        displayName: viewModel.displayName(for:),
                        onSeek: { audioController.seek(toSeconds: $0) }
                    )
                }
                Tab(NarrowSection.notes.title, systemImage: "note.text", value: .notes) {
                    notesBody
                }
            }
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

    /// The Listen Back transport when audio resolves; otherwise the honest missing-file reason
    /// (opaque content layer — a status note, not a control).
    @ViewBuilder
    private var audioSection: some View {
        // A `nil` audioReference means "the transport is absent" (there's no recording) — the
        // missing-file reason text is reserved for a REAL reference that didn't resolve.
        if viewModel.meeting.value?.audioReference == nil {
            EmptyView()
        } else {
            switch viewModel.audio {
            case .available:
                ListenBackPanel(controller: audioController)
            case let .missing(reason):
                Text(reason)
                    .marginaliaTextStyle(.caption, in: scheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MarginaliaSpacing.md.value)
            case .unresolved:
                EmptyView()
            }
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
        }
        .padding(.horizontal, MarginaliaSpacing.md.value)
        .padding(.top, MarginaliaSpacing.md.value)
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
