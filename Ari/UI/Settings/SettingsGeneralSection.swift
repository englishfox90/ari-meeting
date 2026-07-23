//
//  SettingsGeneralSection.swift — General settings (docs/plans/settings-ui.md §6).
//
//  Appearance is LIVE (native theme, backed by the same `UserDefaults` key `AriApp` binds via
//  `@AppStorage`). Notch / menu-bar / recording-alerts are HONEST-DISABLED — each surfaces its
//  own real `Availability.disabled(reason:)` from the VM via `SettingsDisabledGroup`, never a
//  fabricated banner. The recordings-path row is LIVE: it resolves the real on-disk folder
//  (mirroring `AppEnvironment`'s own Application Support layout) and opens it in Finder.
//
import AppKit
import AriKit
import AriViewModels
import SwiftUI

struct SettingsGeneralSection: View {
    let viewModel: SettingsViewModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "General")

            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                SettingsGroup(header: "Appearance") {
                    SettingsRow("Theme") {
                        Picker("Appearance", selection: appearanceBinding) {
                            ForEach(AppAppearance.allCases, id: \.self) { appearance in
                                Text(appearance.rawValue.capitalized).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                SettingsGroup(header: "Notch & Menu Bar") {
                    // The native Swift overlay (docs/plans/notch-panel-absorption.md). Default
                    // OFF, backed by `NotchVisibilityStore` (UserDefaults), not the `setting`
                    // table — same device-local-preference pattern as menu-bar visibility.
                    SettingsToggleRow(
                        "Notch overlay",
                        description: "A live island near the notch during recording — the "
                            + "native Swift version of the meeting notch.",
                        isOn: notchOverlayBinding
                    )
                    .disabled(viewModel.notchOverlayAvailability.isDisabled)

                    SettingsToggleRow(
                        "Show in menu bar",
                        description: viewModel.menuBarAvailability.disabledReason
                            ?? "A quick-access menu-bar item for recording and upcoming meetings.",
                        isOn: showInMenuBarBinding
                    )
                    .disabled(viewModel.menuBarAvailability.isDisabled)
                }

                VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                    if let message = notificationAuthorizationBannerMessage {
                        MarginaliaBanner(kind: .info, message: message, scheme: scheme)
                        if viewModel.notificationAuthorization == .notDetermined {
                            Button("Allow Notifications") {
                                Task { await viewModel.requestNotificationAuthorization() }
                            }
                            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                        }
                    }

                    SettingsGroup(header: "Notifications") {
                        SettingsToggleRow(
                            "Meeting reminders",
                            description: "A heads-up before a calendar meeting starts, "
                                + "with a one-tap Start Recording.",
                            isOn: meetingRemindersBinding
                        )
                        .disabled(viewModel.notificationsAvailability.isDisabled)

                        SettingsRow("Remind me before") {
                            Picker("Lead time", selection: reminderLeadBinding) {
                                ForEach(SettingsViewModel.reminderLeadOptions, id: \.self) { minutes in
                                    Text("\(minutes) min").tag(minutes)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                        .disabled(
                            viewModel.notificationsAvailability.isDisabled || !viewModel.meetingReminders
                        )

                        SettingsToggleRow(
                            "Summary ready",
                            description: "Notify when a summary that took a while to generate is ready.",
                            isOn: summaryReadyBinding
                        )
                        .disabled(viewModel.notificationsAvailability.isDisabled)

                        SettingsToggleRow(
                            "Recording alerts",
                            description: viewModel.recordingAlertsAvailability.disabledReason
                                ?? "Notify when a recording starts or stops.",
                            isOn: recordingAlertsBinding
                        )
                        .disabled(viewModel.recordingAlertsAvailability.isDisabled)
                    }
                }

                SettingsGroup(header: "Recordings folder") {
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                        Text(recordingsFolderDisplayPath)
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                        Button("Open Folder", action: openRecordingsFolder)
                            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                            .disabled(recordingsFolderURL == nil)
                    }
                    .settingsRowInsets()
                }
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)
        }
    }

    // MARK: - Appearance

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { viewModel.appearance.appearance },
            set: { viewModel.appearance.appearance = $0 }
        )
    }

    // MARK: - Honest-disabled toggle bindings

    /// Menu-bar visibility is UserDefaults-backed (like `appearanceBinding`), not a
    /// `SettingsRepository` row — writing the store synchronously flips `AriApp`'s
    /// `@AppStorage(MenuBarVisibilityStore.defaultsKey)` gate, inserting/removing the `MenuBarExtra`
    /// live (docs/plans/menu-bar-item.md).
    private var showInMenuBarBinding: Binding<Bool> {
        Binding(
            get: { viewModel.menuBar.isVisible },
            set: { viewModel.menuBar.isVisible = $0 }
        )
    }

    /// Notch-overlay visibility is UserDefaults-backed (like `showInMenuBarBinding`), not a
    /// `SettingsRepository` row — writing the store synchronously is observed by
    /// `NotchOverlayCoordinator` (`UserDefaults.didChangeNotification`), inserting/removing the
    /// panel live (docs/plans/notch-panel-absorption.md §6).
    private var notchOverlayBinding: Binding<Bool> {
        Binding(
            get: { viewModel.notchOverlay.isVisible },
            set: { viewModel.notchOverlay.isVisible = $0 }
        )
    }

    private var recordingAlertsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.recordingAlerts },
            set: { newValue in Task { try? await viewModel.setRecordingAlerts(newValue) } }
        )
    }

    private var meetingRemindersBinding: Binding<Bool> {
        Binding(
            get: { viewModel.meetingReminders },
            set: { newValue in Task { try? await viewModel.setMeetingReminders(newValue) } }
        )
    }

    private var summaryReadyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.summaryReadyNotification },
            set: { newValue in Task { try? await viewModel.setSummaryReadyNotification(newValue) } }
        )
    }

    private var reminderLeadBinding: Binding<Int> {
        Binding(
            get: { viewModel.reminderLeadMinutes },
            set: { newValue in Task { try? await viewModel.setReminderLeadMinutes(newValue) } }
        )
    }

    /// The honest notification-authorization banner copy — `nil` (no banner) when the OS will
    /// deliver (`.authorized`/`.provisional`) or the state is unknown/unwired. `.notDetermined`
    /// pairs with an "Allow Notifications" button; `.denied` points to System Settings (the OS
    /// won't re-prompt once denied).
    private var notificationAuthorizationBannerMessage: String? {
        switch viewModel.notificationAuthorization {
        case .denied:
            return "Notifications are turned off for Ari in System Settings — reminders and "
                + "summary alerts won't appear until you allow them."
        case .notDetermined:
            return "Ari hasn't been allowed to send notifications yet — allow them so reminders "
                + "and summary alerts can appear."
        case .authorized, .provisional, .none:
            return nil
        }
    }

    // MARK: - Recordings folder

    /// Mirrors `AppEnvironment`'s own `recordingsRootURL()` layout
    /// (`Application Support/<bundleIdentifier>/recordings`) without creating the directory here —
    /// by the time Settings is visible the app has already bootstrapped and created it. Honest
    /// `nil` (no fabricated path) if Application Support can't be resolved.
    private var recordingsFolderURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return support
            .appendingPathComponent(AppEnvironment.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }

    private var recordingsFolderDisplayPath: String {
        recordingsFolderURL?.path ?? "The recordings folder isn't available yet."
    }

    private func openRecordingsFolder() {
        guard let recordingsFolderURL else { return }
        NSWorkspace.shared.open(recordingsFolderURL)
    }
}
