//
//  CalendarPageView.swift — the native Calendar page (docs/plans/arikit-calendar-ui.md §2/§3),
//  Slices 1-3 (read-only week grid; event detail + linking; start meeting from event).
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
    /// `nil` until `AppEnvironment.bootstrap()` constructs the real session — Start stays
    /// honestly disabled until then (`EventDetailSheet`'s own posture).
    let recordingSession: RecordingSession?
    @Binding var selection: SidebarSection
    let onOpenMeeting: (MeetingID) -> Void

    @State private var viewModel: CalendarPageViewModel
    @State private var selectedEvent: CalendarEvent?
    @Environment(\.colorScheme) private var scheme

    init(
        database: AppDatabase,
        calendarSource: (any CalendarSourcing)?,
        recordingSession: RecordingSession?,
        selection: Binding<SidebarSection>,
        onOpenMeeting: @escaping (MeetingID) -> Void,
        onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)? = nil
    ) {
        self.database = database
        self.recordingSession = recordingSession
        _selection = selection
        self.onOpenMeeting = onOpenMeeting
        _viewModel = State(initialValue: CalendarPageViewModel(
            database: database, source: calendarSource, onAutoSeriesMembership: onAutoSeriesMembership
        ))
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
        .sheet(item: $selectedEvent) { event in
            EventDetailSheet(
                event: event,
                linkedMeetingTitle: event.meetingId.flatMap { viewModel.linkedMeetingTitles[$0] },
                resolvedAttendeeNames: viewModel.resolvedAttendeeNames,
                recordingSession: recordingSession,
                onLink: { meetingId in
                    await viewModel.link(eventId: event.id, to: meetingId)
                    refreshSelectedEvent()
                },
                onUnlink: {
                    await viewModel.unlink(eventId: event.id)
                    refreshSelectedEvent()
                },
                onOpenMeeting: { meetingId in
                    selectedEvent = nil
                    onOpenMeeting(meetingId)
                },
                onStartMeeting: { startMeeting(from: event) },
                meetingsForPicker: { await viewModel.meetingsForPicker() },
                onDismiss: { selectedEvent = nil }
            )
        }
    }

    /// Re-reads the just-linked/unlinked event from the VM's freshly-refetched list so the open
    /// detail sheet reflects the real persisted state — never the stale snapshot it was
    /// presented with (No-Fake-State: "Linked" renders only from a real `event.meetingId` read
    /// back from the store, plan §5).
    private func refreshSelectedEvent() {
        guard let current = selectedEvent else { return }
        selectedEvent = viewModel.events.first { $0.id == current.id } ?? current
    }

    /// The Calendar page's "Start meeting" handoff (plan §5): only if a session exists and isn't
    /// already active (defense-in-depth alongside `EventDetailSheet`'s own disabled state).
    /// `pendingTitle` is set only when blank — never clobbers user input already in the field.
    private func startMeeting(from event: CalendarEvent) {
        guard let recordingSession, !recordingSession.isActive else { return }
        // A previous session parked in .saved/.failed would render its terminal screen instead
        // of the idle one — the chip would be invisible and "New recording" would reset() the
        // intent away. Reset first (a safe no-op in .idle) so the handoff always lands on the
        // idle screen with the chip showing.
        recordingSession.reset()
        if recordingSession.pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordingSession.pendingTitle = event.title
        }
        recordingSession.pendingCalendarLink = RecordingSession.PendingCalendarLink(
            eventId: event.id, eventTitle: event.title
        )
        selectedEvent = nil
        selection = .newMeeting
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
            // A failed background refresh must be disclosed even though the stored events below
            // are honest — the user is otherwise looking at stale data with no hint (plan §4).
            if let error = viewModel.refreshError {
                MarginaliaBanner(kind: .error, message: "Calendar refresh failed: \(error)", scheme: scheme)
                    .padding(.horizontal, MarginaliaSpacing.md.value)
            }
            CalendarWeekGrid(
                weekDays: CalendarWeekLayout.weekDays(containing: viewModel.weekStart, calendar: .current),
                events: viewModel.events,
                calendarColors: viewModel.calendarColors,
                linkedMeetingTitles: viewModel.linkedMeetingTitles,
                now: Date(),
                calendar: .current,
                onSelectEvent: { selectedEvent = $0 }
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
