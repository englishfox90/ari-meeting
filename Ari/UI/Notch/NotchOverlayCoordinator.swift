//
//  NotchOverlayCoordinator.swift — owns the in-process notch overlay's on/off lifecycle
//  (docs/plans/notch-panel-absorption.md §2, §6, §10 step 3).
//
//  Small `@MainActor` object owned by `AppEnvironment`: observes the `showNotchOverlay`
//  UserDefaults key (`NotchVisibilityStore`) via `UserDefaults.didChangeNotification` (main
//  queue, `MainActor.assumeIsolated` — the sidecar's own observer pattern,
//  `IslandPanelController.swift:215-221`), and constructs/tears down the `NotchPanelController` +
//  `NotchOverlayModel` accordingly. Default OFF (plan §1 decision) — no panel exists until the
//  Settings toggle is turned on.
//
//  Amendment A (docs/plans/notch-panel-absorption.md §A.3): constructs a `NotchUpcomingScheduler`
//  alongside the panel/model when the overlay turns on, and drops it on disable — the scheduler's
//  30 s tick only runs while its one consumer (this coordinator's `NotchOverlayModel`) exists.
//
import AriKit
import AriViewModels
import Foundation

@MainActor
final class NotchOverlayCoordinator {
    private let session: RecordingSession
    private let database: AppDatabase
    private let onOpenApp: @MainActor () -> Void
    private let onRecordEvent: @MainActor (CalendarEventID) -> Void
    private let store = NotchVisibilityStore()

    private var model: NotchOverlayModel?
    private var upcomingScheduler: NotchUpcomingScheduler?
    private var panelController: NotchPanelController?
    /// `nonisolated(unsafe)`: `deinit` isn't main-actor isolated, but it only ever calls
    /// `NotificationCenter.removeObserver`, which Apple documents as thread-safe — the ONLY
    /// access from off the main actor (plan §3 "deinit caveat", same justification as
    /// `NotchPanelController.observers`).
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(
        session: RecordingSession,
        database: AppDatabase,
        onOpenApp: @escaping @MainActor () -> Void,
        onRecordEvent: @escaping @MainActor (CalendarEventID) -> Void
    ) {
        self.session = session
        self.database = database
        self.onOpenApp = onOpenApp
        self.onRecordEvent = onRecordEvent
        applyVisibility(store.isVisible)
        installObserver()
    }

    private func installObserver() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDefaultsChange() }
        }
    }

    /// `UserDefaults.didChangeNotification` fires on ANY defaults write, not just ours — cheap
    /// to re-evaluate, and the guard below makes an unrelated write a no-op (no panel
    /// churn) unless the visibility preference actually flipped.
    private func handleDefaultsChange() {
        let visible = store.isVisible
        guard visible != (panelController != nil) else { return }
        applyVisibility(visible)
    }

    private func applyVisibility(_ visible: Bool) {
        if visible {
            guard panelController == nil else { return }
            let scheduler = NotchUpcomingScheduler(database: database, session: session)
            upcomingScheduler = scheduler
            let model = NotchOverlayModel(
                session: session,
                upcoming: scheduler,
                onOpenApp: onOpenApp,
                onRecordEvent: onRecordEvent
            )
            self.model = model
            let controller = NotchPanelController(model: model)
            controller.show()
            panelController = controller
        } else {
            panelController?.hide()
            panelController = nil
            model = nil
            upcomingScheduler = nil
        }
    }

    deinit {
        // `deinit` isn't main-actor isolated, but `NotificationCenter` removal is documented
        // thread-safe (same justification as `NotchPanelController.deinit`).
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        // Also order the panel out, not just drop the observer, so a released coordinator can
        // never strand a visible island. `MainActor.assumeIsolated` is safe here: this
        // coordinator is constructed by, and stored only on, `AppEnvironment` (itself
        // `@MainActor`), and `panelController` is otherwise only ever mutated from
        // `applyVisibility`/`handleDefaultsChange`, both already main-actor-isolated — so every
        // path that can release the coordinator's last strong reference (and thus run this
        // deinit) is already on the main actor.
        MainActor.assumeIsolated {
            panelController?.hide()
        }
    }
}
