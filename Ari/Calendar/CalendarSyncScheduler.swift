//
//  CalendarSyncScheduler.swift — the S7 background sync loop (plan §2.1/§3), parity with
//  `spawn_background_sync` (`sync.rs:19-22, 180-239`), including its skip conditions.
//
//  A single `Task` owned by `AppEnvironment`: 5 s initial delay, then every 15 min, skip unless
//  permission is `.fullAccess` AND at least one calendar is selected, else run one
//  `CalendarSyncEngine.syncDefaultWindow()` pass. Best-effort — a sync failure is swallowed
//  (`try?`), never crashes the loop; cancelled in `deinit`.
//
//  `Sendable` by construction: its one stored property is an immutable `Task<Void, Never>`
//  (itself `Sendable` for `Sendable` Success/Failure types), so no `@unchecked Sendable` is
//  needed to hand this to `AppEnvironment` (a `@MainActor` type).
//
import AriKit
import Foundation

final class CalendarSyncScheduler: Sendable {
    private static let initialDelay: Duration = .seconds(5)
    private static let interval: Duration = .seconds(15 * 60)

    private let task: Task<Void, Never>

    init(source: any CalendarSourcing, engine: CalendarSyncEngine, database: AppDatabase) {
        task = Task {
            try? await Task.sleep(for: Self.initialDelay)
            while !Task.isCancelled {
                await Self.runOnce(source: source, engine: engine, database: database)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    deinit {
        task.cancel()
    }

    private static func runOnce(
        source: any CalendarSourcing,
        engine: CalendarSyncEngine,
        database: AppDatabase
    ) async {
        guard await source.permissionStatus() == .fullAccess else { return }
        guard let selectedIds = try? await database.calendarEvents.selectedCalendarIds(),
              !selectedIds.isEmpty else {
            return
        }
        _ = try? await engine.syncDefaultWindow()
    }
}
