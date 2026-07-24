//
//  CalendarSettingsViewModel.swift — the Settings > Calendar section's view model
//  (docs/plans/settings-ui.md §5, S7 EventKit slice docs/plans/arikit-calendar.md §5).
//
//  Goes live behind an OPTIONAL injected `any CalendarSourcing`: `nil` (the default, and what
//  headless construction — tests, previews — gets) keeps today's honest `.notDetermined` +
//  disabled grant, exactly as before this slice. A real source (the app target's
//  `EventKitCalendarSource`, injected by `AppEnvironment`) flips every surface to live: real
//  permission reads, a working grant button, a real synced calendar list, and `syncNow()`.
//  `calendars` always reads the real `CalendarEventRepository.syncSettings()` rows — honestly
//  empty until a real sync populates `calendarSyncSetting` (No-Fake-State — no placeholder rows).
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class CalendarSettingsViewModel {
    /// Real Calendar/EventKit access state, mapped from `CalendarPermission` (`.restricted` folds
    /// into `.denied` — both are "not usable for reads", the same posture `eventkit.rs:20-30`
    /// takes toward `.writeOnly`). `.notDetermined` when no source is injected — never fabricated
    /// as `.granted`.
    public enum PermissionState: Sendable, Equatable {
        case notDetermined
        case granted
        case denied
    }

    /// One configured calendar's sync selection — the `calendarSyncSetting` row shape
    /// (plan §2.1; no dedicated domain DTO exists yet, arikit-models.md §7.7).
    public struct CalendarSyncRow: Sendable, Equatable, Identifiable {
        public var id: String {
            calendarId
        }

        public var calendarId: String
        public var calendarTitle: String?
        public var color: String?
        public var selected: Bool
    }

    public private(set) var permission: PermissionState = .notDetermined
    public private(set) var calendars: [CalendarSyncRow] = []
    /// The most recent `syncNow()` report — real counts only (No-Fake-State). `nil` before any
    /// sync has run this session.
    public private(set) var lastSyncReport: CalendarSyncReport?
    /// The durable last-sync timestamp read from the store (`MAX(syncedAt)`), surviving
    /// view-model recreation and app restarts — `nil` only when no sync has ever written a row.
    public private(set) var lastSyncedAt: Date?
    /// The real error from the most recent failed sync. `nil` when the last sync (if any)
    /// succeeded, or none has run — never both a report and an error at once.
    public private(set) var lastSyncError: String?

    /// `.live` only when a real `CalendarSourcing` was injected; otherwise the honest-disabled
    /// reason, unchanged from before this slice.
    public var grantAccessAvailability: Availability {
        source == nil
            ? .disabled(reason: "Calendar/EventKit access hasn't been wired into the Swift app yet.")
            : .live
    }

    private let database: AppDatabase
    private let source: (any CalendarSourcing)?
    /// The F9 series-ledger fold hook, threaded into `CalendarSyncEngine` so VM-triggered syncs
    /// fold too (calendar-series-intelligence plan §2.4). `nil` by default.
    private let onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)?

    public init(
        database: AppDatabase,
        source: (any CalendarSourcing)? = nil,
        onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)? = nil
    ) {
        self.database = database
        self.source = source
        self.onAutoSeriesMembership = onAutoSeriesMembership
    }

    /// One-shot load. When a source is injected: re-reads the authoritative permission, and — if
    /// access is `.fullAccess` — refreshes the calendar list live from the source (identity
    /// refresh preserves `selected`, plan §4 item 6). Falls back to the stored rows otherwise (no
    /// source, or a failed read leaves the last honest value rather than fabricating a list).
    public func load() async {
        if let source {
            permission = Self.map(await source.permissionStatus())
        }
        lastSyncedAt = try? await database.calendarEvents.latestSyncedAt()
        if permission == .granted, let engine, let rows = try? await engine.refreshCalendarList() {
            calendars = rows.map(Self.row)
            return
        }
        guard let rows = try? await database.calendarEvents.syncSettings() else { return }
        calendars = rows.map(Self.row)
    }

    /// Requests EventKit full access, then re-reads the authoritative status rather than
    /// assuming `.denied` on a refusal (parity: `eventkit.rs:63-71`) — a no-op when no source is
    /// injected. On a grant, immediately refreshes the calendar list.
    public func requestAccess() async {
        guard let source else { return }
        _ = try? await source.requestFullAccess()
        permission = Self.map(await source.permissionStatus())
        if permission == .granted {
            await load()
        }
    }

    /// Round-trips a calendar's sync selection through `CalendarEventRepository.setSyncSetting`,
    /// preserving its known title/color.
    public func setSelected(_ selected: Bool, for calendarId: String) async throws {
        let existing = calendars.first { $0.calendarId == calendarId }
        try await database.calendarEvents.setSyncSetting(
            calendarId: calendarId,
            calendarTitle: existing?.calendarTitle,
            color: existing?.color,
            selected: selected
        )
        if let index = calendars.firstIndex(where: { $0.calendarId == calendarId }) {
            calendars[index].selected = selected
        } else {
            calendars.append(
                CalendarSyncRow(calendarId: calendarId, calendarTitle: nil, color: nil, selected: selected)
            )
        }
    }

    /// Runs a full default-window sync (`CalendarSyncEngine.syncDefaultWindow`) and surfaces the
    /// real report, or the real error — never a fabricated count (No-Fake-State). A no-op when no
    /// source is injected. Re-reads the authoritative permission first: a grant revoked in System
    /// Settings mid-session must not run a sync whose empty fetch would tombstone the whole
    /// window (mirrors `CalendarSyncScheduler.runOnce`'s guard).
    public func syncNow() async {
        guard let source, let engine else { return }
        permission = Self.map(await source.permissionStatus())
        guard permission == .granted else { return }
        do {
            let report = try await engine.syncDefaultWindow()
            lastSyncReport = report
            lastSyncError = nil
            lastSyncedAt = try? await database.calendarEvents.latestSyncedAt()
            if let rows = try? await database.calendarEvents.syncSettings() {
                calendars = rows.map(Self.row)
            }
        } catch {
            lastSyncReport = nil
            lastSyncError = String(describing: error)
        }
    }

    /// Constructed fresh per use from `source` + `database` — cheap (a `Sendable` value type
    /// wrapping two references), so there's no separate stored-engine identity to keep in sync.
    private var engine: CalendarSyncEngine? {
        source.map {
            CalendarSyncEngine(source: $0, database: database, onAutoSeriesMembership: onAutoSeriesMembership)
        }
    }

    private static func row(
        _ tuple: (calendarId: String, calendarTitle: String?, color: String?, selected: Bool)
    ) -> CalendarSyncRow {
        CalendarSyncRow(
            calendarId: tuple.calendarId,
            calendarTitle: tuple.calendarTitle,
            color: tuple.color,
            selected: tuple.selected
        )
    }

    private static func map(_ permission: CalendarPermission) -> PermissionState {
        switch permission {
        case .fullAccess: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        }
    }
}
