//
//  TaskCancellationCoordinator.swift — per-meeting cancellation registry for summary generation
//  (plan §3, ← the Rust module-static `CANCELLATION_REGISTRY` + `CancellationToken`,
//  `ari-engine/src/summary/service.rs:28-30,226-255`).
//
//  Rust guards concurrent summary cancellation with a global `Lazy<Arc<Mutex<HashMap<String,
//  CancellationToken>>>>` (`CANCELLATION_REGISTRY`). Swift's strict-concurrency-clean equivalent is
//  an `actor` holding cancel closures keyed by `MeetingID` — no global mutable state, no
//  `@unchecked Sendable` / `nonisolated(unsafe)`. Mirrors `ReindexCoordinator`
//  (`Recall/Indexer/ReindexCoordinator.swift`), just keyed per-meeting instead of a single flag.
//
import Foundation

public actor TaskCancellationCoordinator {
    private var cancelHandlers: [MeetingID: @Sendable () -> Void] = [:]

    public init() {}

    /// Registers a cancellation handle for `meetingId` (← `register_cancellation_token`).
    /// Overwrites any previous handle for the same meeting — mirrors the Rust `HashMap::insert`
    /// overwrite semantics (only one generation is expected to run per meeting at a time).
    func register(_ meetingId: MeetingID, cancel: @escaping @Sendable () -> Void) {
        cancelHandlers[meetingId] = cancel
    }

    /// ← `cleanup_cancellation_token`. Removes the handle after processing completes (success,
    /// failure, or cancellation) — safe to call even if nothing was registered.
    func unregister(_ meetingId: MeetingID) {
        cancelHandlers.removeValue(forKey: meetingId)
    }

    /// ← `SummaryService::cancel_summary`. Returns `true` if an active generation was found and
    /// cancelled; `false` if none was running for this meeting.
    public func cancel(_ meetingId: MeetingID) -> Bool {
        guard let cancel = cancelHandlers[meetingId] else {
            return false
        }
        cancel()
        return true
    }
}
