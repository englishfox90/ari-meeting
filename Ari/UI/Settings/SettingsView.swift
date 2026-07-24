//
//  SettingsView.swift — the native Settings screen shell (docs/plans/settings-ui.md §6).
//
//  Full-window in the detail column (NOT a sheet). The section switcher lives in the toolbar via
//  `ToolbarItem(placement: .principal)` + a stock segmented `Picker` — glass comes from the
//  toolbar/chrome layer, never content. `MarginaliaSegmentedControl`/`MarginaliaGlassTabs` are
//  BANNED here (mirrors the narrow-meeting-switcher precedent, `MeetingDetailView`).
//
//  Owns both view models (constructed in `init`, loaded once via `.task`) so every section slice
//  composes against an already-loaded VM rather than re-fetching.
//
import AriKit
import AriViewModels
import SwiftUI

struct SettingsView: View {
    let database: AppDatabase

    @State private var tab: SettingsTab = .general
    @State private var viewModel: SettingsViewModel
    @State private var calendarViewModel: CalendarSettingsViewModel

    @Environment(\.colorScheme) private var scheme

    /// `calendarSource` is `nil` until `AppEnvironment.bootstrap()` constructs the real
    /// `EventKitCalendarSource` (S7) — `CalendarSettingsViewModel` stays honestly disabled until
    /// then, never fabricating a live source.
    init(
        database: AppDatabase,
        calendarSource: (any CalendarSourcing)? = nil,
        notifications: MeetingNotifications? = nil,
        recordingSession: RecordingSession? = nil,
        onAutoSeriesMembership: (@Sendable (MeetingID) async -> Void)? = nil
    ) {
        self.database = database
        // `KeychainSecretStore`/`AppearanceStore` are both stateless value types (no Keychain
        // session, no stored `UserDefaults` handle) — constructing them directly here is
        // equivalent to reading `AppEnvironment.secrets`, without needing environment values
        // (unavailable in `init`).
        //
        // `notifications` (the app's `MeetingNotifications`, or `nil` in previews/tests) is the
        // authorization surface AND the reconcile trigger: toggling a notification pref reconciles
        // the OS's scheduled reminders immediately rather than waiting for the periodic loop.
        let onNotificationSettingsChanged: (@Sendable () async -> Void)? = if let notifications {
            { await notifications.reconcileReminders() }
        } else {
            nil
        }
        // Mirror the consent toggle onto the live session so it takes effect without a restart.
        // `RecordingSession` is `@MainActor`; this closure only runs on the main actor (invoked from
        // the `@MainActor` view model's setter), so the isolation assumption holds.
        let onRecordingRequireConsentChanged: (@Sendable (Bool) -> Void)? = if let recordingSession {
            { value in MainActor.assumeIsolated { recordingSession.requireConsent = value } }
        } else {
            nil
        }
        _viewModel = State(initialValue: SettingsViewModel(
            database: database,
            secrets: KeychainSecretStore(),
            appearance: AppearanceStore(),
            notifications: notifications,
            onNotificationSettingsChanged: onNotificationSettingsChanged,
            onRecordingRequireConsentChanged: onRecordingRequireConsentChanged
        ))
        _calendarViewModel = State(initialValue: CalendarSettingsViewModel(
            database: database, source: calendarSource, onAutoSeriesMembership: onAutoSeriesMembership
        ))
    }

    var body: some View {
        ScrollView {
            content
                .padding(MarginaliaSpacing.md.value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(MarginaliaCanvasWash(scheme: scheme))
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $tab) {
                    ForEach(SettingsTab.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .task {
            async let settingsLoad: () = viewModel.load()
            async let calendarLoad: () = calendarViewModel.load()
            _ = await (settingsLoad, calendarLoad)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general:
            SettingsGeneralSection(viewModel: viewModel)
        case .recordings:
            SettingsRecordingsSection(viewModel: viewModel)
        case .intelligence:
            SettingsIntelligenceSection(viewModel: viewModel)
        case .calendar:
            SettingsCalendarSection(viewModel: calendarViewModel)
        }
    }
}
