//
//  CalendarPageView.swift — the native Calendar page (docs/plans/arikit-calendar-ui.md §2/§3),
//  Slice 1 (read-only week grid).
//
//  Local-DB-first: `load()` renders real synced rows immediately; `syncOnAppear()` refreshes in
//  the background at most once per appearance. Every state is honest (plan §2/§7, No-Fake-State):
//  no access → a message + "Open Settings" jump (flips the sidebar selection); access but never
//  synced → "No events synced yet" + a Sync now affordance; synced but empty week → the empty
//  grid itself — never a fabricated placeholder.
//
import AriKit
import AriViewModels
import SwiftUI

struct CalendarPageView: View {
    let database: AppDatabase
    @Binding var selection: SidebarSection

    @State private var viewModel: CalendarPageViewModel
    @Environment(\.colorScheme) private var scheme

    init(database: AppDatabase, calendarSource: (any CalendarSourcing)?, selection: Binding<SidebarSection>) {
        self.database = database
        _selection = selection
        _viewModel = State(initialValue: CalendarPageViewModel(database: database, source: calendarSource))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.marginalia(.hairline, in: scheme))
                .frame(height: 1)
            content
                .padding(MarginaliaSpacing.md.value)
        }
        .background(MarginaliaCanvasWash(scheme: scheme))
        .navigationTitle("Calendar")
        .task {
            await viewModel.load()
            await viewModel.syncOnAppear()
        }
    }

    // MARK: - Header: `‹ Today ›` pager + week-range label

    private var header: some View {
        HStack(spacing: MarginaliaSpacing.md.value) {
            pager
            Spacer(minLength: MarginaliaSpacing.md.value)
            Text(weekRangeLabel)
                .marginaliaTextStyle(.headline, in: scheme)
            Spacer()
            if viewModel.isSyncing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(MarginaliaSpacing.md.value)
    }

    private var pager: some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            Button {
                Task { await viewModel.showPreviousWeek() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))

            Button("Today") {
                Task { await viewModel.showToday() }
            }
            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))

            Button {
                Task { await viewModel.showNextWeek() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
        }
    }

    /// e.g. "Jul 13 – 19, 2026" or "Jul 27 – Aug 2, 2026" across a month boundary.
    private var weekRangeLabel: String {
        let calendar = Calendar.current
        let start = viewModel.weekStart
        guard let end = calendar.date(byAdding: .day, value: 6, to: start) else { return "" }
        let sameMonth = calendar.isDate(start, equalTo: end, toGranularity: .month)
            && calendar.isDate(start, equalTo: end, toGranularity: .year)
        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let endText = sameMonth
            ? end.formatted(.dateTime.day())
            : end.formatted(.dateTime.month(.abbreviated).day())
        let year = calendar.component(.year, from: end)
        return "\(startText) – \(endText), \(year)"
    }

    // MARK: - Content: honest state switch (plan §2/§7)

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noAccess:
            noAccessState
        case .neverSynced:
            neverSyncedState
        case .ready:
            CalendarWeekGrid(
                weekDays: CalendarWeekLayout.weekDays(containing: viewModel.weekStart, calendar: .current),
                events: viewModel.events,
                calendarColors: viewModel.calendarColors,
                linkedMeetingTitles: viewModel.linkedMeetingTitles,
                now: Date(),
                calendar: .current
            )
        }
    }

    private var noAccessState: some View {
        VStack(spacing: MarginaliaSpacing.md.value) {
            Image("DictationMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(96.0 / 64.0, contentMode: .fit)
                .frame(width: 56)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
            Text("Ari doesn't have Calendar access yet.")
                .marginaliaTextStyle(.body, in: scheme)
            Button("Open Settings") {
                selection = .settings
            }
            .buttonStyle(.marginalia(.primary, .large, in: scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var neverSyncedState: some View {
        VStack(spacing: MarginaliaSpacing.md.value) {
            Text("No events synced yet.")
                .marginaliaTextStyle(.body, in: scheme)
            Button("Sync now") {
                Task {
                    await viewModel.syncOnAppear()
                    await viewModel.load()
                }
            }
            .buttonStyle(.marginalia(.primary, .large, in: scheme))
            .disabled(viewModel.isSyncing)
            if let error = viewModel.refreshError {
                MarginaliaBanner(kind: .error, message: error, scheme: scheme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
