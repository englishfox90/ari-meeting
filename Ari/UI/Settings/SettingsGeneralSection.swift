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
                    SettingsToggleRow(
                        "Show meeting notch",
                        description: viewModel.notchAvailability.disabledReason
                            ?? "A live HUD near the notch during recording.",
                        isOn: showNotchBinding
                    )
                    .disabled(viewModel.notchAvailability.isDisabled)

                    SettingsToggleRow(
                        "Show in menu bar",
                        description: viewModel.menuBarAvailability.disabledReason
                            ?? "A quick-access menu-bar item.",
                        isOn: showInMenuBarBinding
                    )
                    .disabled(viewModel.menuBarAvailability.isDisabled)
                }

                SettingsGroup(header: "Notifications") {
                    SettingsToggleRow(
                        "Recording alerts",
                        description: viewModel.recordingAlertsAvailability.disabledReason
                            ?? "Notify when a recording starts or stops.",
                        isOn: recordingAlertsBinding
                    )
                    .disabled(viewModel.recordingAlertsAvailability.isDisabled)
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

    private var showNotchBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showNotch },
            set: { newValue in Task { try? await viewModel.setShowNotch(newValue) } }
        )
    }

    private var showInMenuBarBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showInMenuBar },
            set: { newValue in Task { try? await viewModel.setShowInMenuBar(newValue) } }
        )
    }

    private var recordingAlertsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.recordingAlerts },
            set: { newValue in Task { try? await viewModel.setRecordingAlerts(newValue) } }
        )
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
