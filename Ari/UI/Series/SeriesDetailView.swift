//
//  SeriesDetailView.swift — the series "connected record": one recurring purpose seen across
//  every meeting in it (plan §2.2 Series, §9 S6f).
//
//  A series binds recurring meetings — e.g. every 1:1 with the same report — into a single
//  running record. The screen leads with the LEDGER (the rolling tally of open items, decisions,
//  themes, and per-person threads carried meeting to meeting), then the TIMELINE of member
//  meetings. The ledger's cross-meeting citation chips (`@mref`) are what make it *connected*:
//  each claim links back to the exact moment in the source meeting it came from.
//
//  Rich ledger rendering goes through `MarginaliaMarkdownView` (headings / the action-items table /
//  per-person bullet threads), not the flattened inline `MarkdownText`. Every section renders real
//  data only and states an honest empty when it's absent (No-Fake-State).
//
import AriKit
import AriViewModels
import SwiftUI

struct SeriesDetailView: View {
    let database: AppDatabase
    let seriesId: SeriesID
    /// Opens a member meeting at a cited moment (member id + recording-relative seconds), routed by
    /// the shell onto the shared navigation stack. Backs the ledger's `@mref` citation chips.
    let onOpenMeetingMoment: (MeetingID, Double) -> Void

    @State private var viewModel: SeriesDetailViewModel
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    /// This view's live registration on `environment.askNavTracker` (bug fix, 2026-07-24) —
    /// mirrors `MeetingDetailView.askNavToken`. Pushed/replaced in `.task(id: seriesId)`, removed
    /// in `.onDisappear`.
    @State private var askNavToken: AskNavTracker.Token?

    /// Local UI state for the toolbar's Rename / Merge / Delete affordances (plan Part 4).
    @State private var showRenameSheet = false
    @State private var renameText = ""
    @State private var showMergeSheet = false
    @State private var mergeTargetId: SeriesID?
    @State private var showDeleteConfirm = false
    @State private var showMergeConfirm = false

    init(
        database: AppDatabase,
        seriesId: SeriesID,
        ledgerReducer: SeriesLedgerReducer,
        onOpenMeetingMoment: @escaping (MeetingID, Double) -> Void
    ) {
        self.database = database
        self.seriesId = seriesId
        self.onOpenMeetingMoment = onOpenMeetingMoment
        _viewModel = State(initialValue: SeriesDetailViewModel(database: database, ledgerReducer: ledgerReducer))
    }

    // No own `NavigationStack`: this view is pushed onto the shell's outer stack, which owns the
    // `navigationDestination(for:)` entries. Member-meeting rows push via `NavigationLink(value:)`
    // and ledger chips push via `onOpenMeetingMoment`, so back-navigation and the toolbar stay
    // consistent (no nested stack / double bar).
    var body: some View {
        StateContainer(
            state: viewModel.series,
            emptyTitle: "No series",
            emptyMessage: nil
        ) { series in
            content(for: series)
        }
        .background(Color.marginalia(.canvas, in: scheme))
        .navigationTitle(viewModel.series.value?.title ?? "Series")
        .task(id: seriesId) {
            // Ask-nav presence (bug fix, 2026-07-24) — see `MeetingDetailView`'s identical
            // `.task(id:)`-driven push/replace for why this isn't just `.onAppear`.
            if let askNavToken {
                environment.askNavTracker.remove(askNavToken)
            }
            askNavToken = environment.askNavTracker.push(.series(seriesId))
            await viewModel.load(seriesId)
        }
        .onDisappear {
            if let askNavToken {
                environment.askNavTracker.remove(askNavToken)
                self.askNavToken = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .help("Back")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename") {
                        viewModel.clearError()
                        renameText = viewModel.series.value?.title ?? ""
                        showRenameSheet = true
                    }
                    Button("Merge into…") {
                        viewModel.clearError()
                        mergeTargetId = viewModel.mergeTargets.first?.id
                        showMergeSheet = true
                    }
                    .disabled(viewModel.mergeTargets.isEmpty)
                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                // M3: no two mutations may overlap — a rebuild in flight must block Rename/Merge/
                // Delete just as much as another rename/merge/delete would (e.g. Delete firing
                // mid-rebuild would write a fresh ledger to a series it just tombstoned).
                .disabled(viewModel.isBusy || viewModel.isRebuildingLedger)
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(isPresented: $showMergeSheet) {
            mergeSheet
        }
        .confirmationDialog(
            "Delete this series?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await viewModel.delete() {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the series and detaches its meetings. The meetings themselves are kept.")
        }
    }

    // MARK: - Rename sheet

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            Text("Rename series")
                .marginaliaTextStyle(.title2, in: scheme, ink: .inkHeading)
            TextField("Series title", text: $renameText)
                .textFieldStyle(.roundedBorder)
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .error)
            }
            HStack {
                Spacer()
                Button("Cancel") { showRenameSheet = false }
                    .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                Button("Save") {
                    Task {
                        await viewModel.rename(to: renameText)
                        if viewModel.errorMessage == nil {
                            showRenameSheet = false
                        }
                    }
                }
                .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                .disabled(viewModel.isBusy)
            }
        }
        .padding(MarginaliaSpacing.xl.value)
        .frame(minWidth: 320)
    }

    // MARK: - Merge sheet

    private var mergeSheet: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            Text("Merge into…")
                .marginaliaTextStyle(.title2, in: scheme, ink: .inkHeading)
            Text("Every meeting in this series moves to the chosen series, and this series is deleted.")
                .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            Picker("Target series", selection: $mergeTargetId) {
                ForEach(viewModel.mergeTargets) { target in
                    Text(target.title).tag(Optional(target.id))
                }
            }
            .pickerStyle(.menu)
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .error)
            }
            HStack {
                Spacer()
                Button("Cancel") { showMergeSheet = false }
                    .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                Button("Merge") { showMergeConfirm = true }
                    .buttonStyle(.marginalia(.primary, .regular, in: scheme))
                    .disabled(viewModel.isBusy || mergeTargetId == nil)
            }
        }
        .padding(MarginaliaSpacing.xl.value)
        .frame(minWidth: 360)
        .confirmationDialog(
            "Merge this series?",
            isPresented: $showMergeConfirm,
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) {
                guard let target = mergeTargetId else { return }
                Task {
                    // This series is now tombstoned by the merge — it no longer exists, so pop
                    // back to the list rather than trying to navigate to the target in place.
                    if await viewModel.merge(into: target) != nil {
                        showMergeSheet = false
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func content(for series: Series) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xl.value) {
                header(for: series)
                ledgerSection(for: series)
                timelineSection
            }
            .padding(MarginaliaSpacing.xl.value)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private func header(for series: Series) -> some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text("Series")
                .marginaliaTextStyle(.caption, in: scheme)
            Text(series.title)
                .marginaliaTextStyle(.title1, in: scheme, ink: .inkHeading)
            if let classification {
                Text(classification)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }
            if let summaryLine {
                Text(summaryLine)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "detectedType · cadence" — whichever exist, joined; `nil` when the series carries neither.
    private var classification: String? {
        let parts = [viewModel.series.value?.detectedType, viewModel.series.value?.cadence]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "N meetings · Last <date>" — a real count and the most recent member's date; the "Last"
    /// clause is dropped when there are no members (No-Fake-State — never a fabricated recency).
    private var summaryLine: String? {
        let count = viewModel.memberMeetings.count
        guard count > 0 else { return nil }
        let countText = "\(count) meeting\(count == 1 ? "" : "s")"
        guard let last = viewModel.memberMeetings.map(\.createdAt).max() else { return countText }
        return "\(countText) · Last \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: - Ledger

    private func ledgerSection(for series: Series) -> some View {
        let hasLedger = series.ledgerMarkdown?.isEmpty == false
        return VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ledger")
                    .marginaliaTextStyle(.caption, in: scheme)
                Spacer()
                if viewModel.isRebuildingLedger {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(hasLedger ? "Rebuild ledger" : "Build ledger") {
                    Task { await viewModel.rebuildLedger() }
                }
                .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                // M3: a rename/merge/delete in flight must also block a rebuild — e.g. a rebuild
                // firing mid-delete would write a ledger to a series that's about to be tombstoned.
                .disabled(viewModel.isRebuildingLedger || viewModel.isBusy)
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
            }
            if let ledgerMarkdown = series.ledgerMarkdown, !ledgerMarkdown.isEmpty {
                panel {
                    MarginaliaMarkdownView(
                        markdown: ledgerMarkdown,
                        onOpenMeetingMoment: handleLedgerMoment(memberIndex:seconds:),
                        meetingMomentCount: viewModel.memberMeetings.count
                    )
                }
            } else {
                panel {
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                        Text("No ledger yet")
                            .marginaliaTextStyle(.body, in: scheme)
                        Text(
                            "The ledger builds after a meeting in this series is summarized — a running tally of open items, decisions, and per-person threads across every meeting."
                        )
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    }
                }
            }
        }
    }

    /// Resolve a 1-based `@mref` member index to its meeting, then open it at the cited moment.
    /// An out-of-range index simply no-ops (the chip is already rendered inert upstream when the
    /// index can't resolve — this is the belt-and-braces guard).
    private func handleLedgerMoment(memberIndex: Int, seconds: Double) {
        guard memberIndex >= 1, memberIndex <= viewModel.memberMeetings.count else { return }
        onOpenMeetingMoment(viewModel.memberMeetings[memberIndex - 1].id, seconds)
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineSection: some View {
        let count = viewModel.memberMeetings.count
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            Text(count == 0 ? "Timeline" : "Timeline · \(count) meeting\(count == 1 ? "" : "s")")
                .marginaliaTextStyle(.caption, in: scheme)
            if viewModel.memberMeetings.isEmpty {
                panel {
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                        Text("No meetings linked yet")
                            .marginaliaTextStyle(.body, in: scheme)
                        Text("Meetings linked to this series will appear here in order.")
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    }
                }
            } else {
                panel(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.memberMeetings.enumerated()), id: \.element.id) { offset, meeting in
                            if offset > 0 {
                                Divider().overlay(Color.marginalia(.hairline, in: scheme))
                            }
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
    }

    // MARK: - Panel

    /// A flat hairline-bordered surface card — the shared container look for the ledger and the
    /// timeline (matches `MarginaliaMarkdownView`'s table framing).
    private func panel(
        padding: CGFloat = MarginaliaSpacing.lg.value,
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .fill(Color.marginalia(.surface, in: scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
            )
    }
}
