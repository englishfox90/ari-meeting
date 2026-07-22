//
//  CalendarSettingsViewModel.swift — the Settings > Calendar section's view model
//  (docs/plans/settings-ui.md §5).
//
//  No EventKit source exists in the Swift app yet (plan §1 scope), so `permission` is honestly
//  `.notDetermined` and never fabricated as granted. `calendars` reads the real
//  `CalendarEventRepository.syncSettings()` rows — honestly empty until a real EventKit sync
//  populates `calendarSyncSetting`, never a placeholder list.
//
import AriKit
import Foundation
import Observation

@MainActor
@Observable
public final class CalendarSettingsViewModel {
    /// Real Calendar/EventKit access state. `.notDetermined` today — no EventKit source exists
    /// in the Swift app yet, so this is never fabricated as `.granted`.
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

    public let grantAccessAvailability: Availability = .disabled(
        reason: "Calendar/EventKit access hasn't been wired into the Swift app yet."
    )

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// One-shot load. A failed read leaves `calendars` at its last honest value rather than
    /// fabricating a list.
    public func load() async {
        guard let rows = try? await database.calendarEvents.syncSettings() else { return }
        calendars = rows.map {
            CalendarSyncRow(
                calendarId: $0.calendarId,
                calendarTitle: $0.calendarTitle,
                color: $0.color,
                selected: $0.selected
            )
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
}
