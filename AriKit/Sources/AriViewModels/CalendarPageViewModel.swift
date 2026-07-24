//
//  CalendarPageViewModel.swift — the native Calendar page's view model
//  (docs/plans/arikit-calendar-ui.md §3/§4).
//
//  Local-DB-first (`page.tsx:57-72`'s posture): `load()`/pager reads render immediately from
//  `CalendarEventRepository`; `syncOnAppear()` is a best-effort background refresh, guarded
//  exactly like `CalendarSyncScheduler.runOnce` (full access + a non-empty selection), and
//  single-flight via `isSyncing`. No live `ValueObservation` in v1 — explicit refetch after a
//  week change / sync / link / unlink is sufficient at single-user scale (plan §4).
//
//  Same optional-source pattern as `CalendarSettingsViewModel`: `nil` source (tests, previews)
//  keeps `state` honestly on the no-access side; the app injects `environment.calendarSource`.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class CalendarPageViewModel {
    /// Every state is backed by a real read (permission, `MAX(syncedAt)`, a row fetch) —
    /// No-Fake-State: the page never claims `.ready` over an unreadable or never-synced
    /// calendar (plan §7).
    public enum PageState: Equatable {
        case loading
        case noAccess
        case neverSynced
        case ready
    }

    public private(set) var state: PageState = .loading
    public private(set) var weekStart: Date
    /// The visible week's events only — real DB rows, never fabricated.
    public private(set) var events: [CalendarEvent] = []
    /// `calendarId` → hex color, from `calendarSyncSetting.color` (real EventKit color, not a
    /// design token).
    public private(set) var calendarColors: [String: String] = [:]
    /// `meetingId` → title, for every linked meeting among `events` — the linked-badge + detail
    /// sheet read this rather than re-querying per row.
    public private(set) var linkedMeetingTitles: [MeetingID: String] = [:]
    public private(set) var isSyncing = false
    /// The real error from the most recent failed background sync, or `nil`. A failed refresh
    /// never clears `events` — the stored data stays honest; only the failed *refresh* is
    /// disclosed (plan §4).
    public private(set) var refreshError: String?

    private let database: AppDatabase
    private let source: (any CalendarSourcing)?
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// The F9 series-ledger fold hook, threaded into `CalendarSyncEngine` so VM-triggered syncs
    /// fold too (calendar-series-intelligence plan §2.4). `nil` by default.
    private let onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)?

    public init(
        database: AppDatabase,
        source: (any CalendarSourcing)? = nil,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)? = nil
    ) {
        self.database = database
        self.source = source
        self.calendar = calendar
        self.now = now
        self.onAutoSeriesMembership = onAutoSeriesMembership
        weekStart = CalendarWeekLayout.weekDays(containing: now(), calendar: calendar).first
            ?? calendar.startOfDay(for: now())
    }

    /// `weekStart ... weekStart+7d` (exclusive of the following week's first instant) — the
    /// range every read/sync call uses.
    public var visibleRange: ClosedRange<Date> {
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart)?.addingTimeInterval(-1) ?? weekStart
        return weekStart ... end
    }

    /// Permission → state, then a local-DB read for the visible week. Never optimistic: `.ready`
    /// is only ever reached after a real `.fullAccess` read AND a real non-nil `latestSyncedAt()`.
    public func load() async {
        state = .loading
        guard let source, await source.permissionStatus() == .fullAccess else {
            state = .noAccess
            events = []
            return
        }
        let latestSynced = (try? await database.calendarEvents.latestSyncedAt()) ?? nil
        guard latestSynced != nil else {
            state = .neverSynced
            events = []
            return
        }
        await refetch()
        state = .ready
    }

    /// Best-effort background sync — mirrors `CalendarSyncScheduler.runOnce`'s guards exactly
    /// (full access AND a non-empty selection); single-flight; the view calls this from `.task`
    /// so it runs at most once per appearance. On success: refetch, clear `refreshError`, and
    /// flip to `.ready` (a successful sync only happens after the same full-access check `load()`
    /// gates on, so this is never an optimistic promotion). On failure: keep the stored events,
    /// surface the real error.
    public func syncOnAppear() async {
        guard !isSyncing else { return }
        guard let source, await source.permissionStatus() == .fullAccess else { return }
        guard let selectedIds = try? await database.calendarEvents.selectedCalendarIds(),
              !selectedIds.isEmpty else {
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let engine = CalendarSyncEngine(
                source: source, database: database, onAutoSeriesMembership: onAutoSeriesMembership
            )
            _ = try await engine.syncDefaultWindow(now: now())
            refreshError = nil
            await refetch()
            state = .ready
        } catch {
            refreshError = String(describing: error)
        }
    }

    public func showPreviousWeek() async {
        guard let newStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) else { return }
        weekStart = newStart
        await refetch()
    }

    public func showNextWeek() async {
        guard let newStart = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { return }
        weekStart = newStart
        await refetch()
    }

    public func showToday() async {
        guard let newStart = CalendarWeekLayout.weekDays(containing: now(), calendar: calendar).first else {
            return
        }
        weekStart = newStart
        await refetch()
    }

    /// Manual link → `setManualLink`; survives re-sync (`syncUpsert` never touches
    /// `meetingId`/`linkSource`, the S7 invariant).
    public func link(eventId: CalendarEventID, to meetingId: MeetingID) async {
        try? await database.calendarEvents.setManualLink(eventId: eventId, meetingId: meetingId)
        await refetch()
    }

    public func unlink(eventId: CalendarEventID) async {
        try? await database.calendarEvents.unlinkMeeting(eventId: eventId)
        await refetch()
    }

    /// Existing meetings for the link picker, newest first (`MeetingRepository.all()`'s own
    /// ordering).
    public func meetingsForPicker() async -> [Meeting] {
        (try? await database.meetings.all()) ?? []
    }

    // MARK: - Local-DB-first read (no EventKit call — repositories only)

    private func refetch() async {
        let range = visibleRange
        events = (try? await database.calendarEvents.events(startingIn: range)) ?? []

        if let rows = try? await database.calendarEvents.syncSettings() {
            var colors: [String: String] = [:]
            for row in rows where row.color != nil {
                colors[row.calendarId] = row.color
            }
            calendarColors = colors
        }

        let meetingIds = Set(events.compactMap(\.meetingId))
        var titles: [MeetingID: String] = [:]
        for meetingId in meetingIds {
            if let meeting = try? await database.meetings.find(meetingId) {
                titles[meetingId] = meeting.title
            }
        }
        linkedMeetingTitles = titles
    }
}
