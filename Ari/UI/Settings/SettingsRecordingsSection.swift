//
//  SettingsRecordingsSection.swift — Recordings settings (docs/plans/settings-ui.md §6).
//
//  Save-audio toggle is LIVE (persists via `SettingsViewModel`). The save-location row is LIVE:
//  it resolves the real on-disk recordings folder (mirroring `AppEnvironment`'s own Application
//  Support layout, same recipe as `SettingsGeneralSection`) and opens it in Finder — never a
//  fabricated path. The file-format caption is LIVE informational copy matching the real
//  capture format (`AriCapture/AACRecorder.swift`: AAC-LC `.m4a`, mono). Recording-start
//  notification and audio backend are HONEST-DISABLED — each surfaces its own real
//  `Availability.disabled(reason:)` from the VM via `SettingsDisabledGroup`, never a
//  fake-functional control.
//
//  Microphone device selection is LIVE (docs/plans/settings-audio-devices.md): real CoreAudio
//  HAL enumeration via `CoreAudioDeviceEnumerator`, persisting a stable device UID that binds
//  into `MicrophoneCapture` at recording start. System audio is an honest READ-ONLY row (not a
//  picker) — `SystemAudioTap` is a single global Core Audio process tap anchored to the default
//  output device, so a per-device system-audio selection could never take effect.
//
import AppKit
import AriKit
import AriViewModels
import SwiftUI

struct SettingsRecordingsSection: View {
    let viewModel: SettingsViewModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "Recordings")

            SettingsCard(title: "Audio") {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                    MarginaliaToggleRow(
                        "Save audio recordings",
                        description: "Keep the recorded audio file alongside the transcript.",
                        isOn: saveAudioRecordingsBinding,
                        scheme: scheme
                    )
                    SettingsDisabledGroup(availability: viewModel.recordingStartNotificationAvailability) {
                        MarginaliaToggleRow(
                            "Notify when recording starts",
                            description: "A system notification the moment capture begins.",
                            isOn: recordingStartNotificationBinding,
                            scheme: scheme
                        )
                    }
                }
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)

            SettingsCard(title: "Save Location") {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                    Text(recordingsFolderDisplayPath)
                        .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                    Button("Open Folder", action: openRecordingsFolder)
                        .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                        .disabled(recordingsFolderURL == nil)
                    Text(fileFormatCaption)
                        .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                }
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)

            SettingsCard(title: "Default Devices") {
                VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                    Picker(selection: micDeviceBinding) {
                        Text("System Default").tag(String?.none)
                        ForEach(viewModel.audioInputDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                        // Honest row for a stored device that isn't currently attached — never
                        // silently dropped (No-Fake-State); disabled since it can't be re-selected.
                        if !viewModel.micDeviceIsPresent, let micDevice = viewModel.micDevice {
                            Text("\(micDevice) (not connected)").tag(Optional(micDevice))
                                .disabled(true)
                        }
                    } label: {
                        MarginaliaMenuLabel(title: "Microphone", scheme: scheme)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                        MarginaliaMenuLabel(title: "System Audio", scheme: scheme)
                        Text(viewModel.defaultOutputDeviceName ?? "Current output device unavailable")
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkBody)
                        Text("System audio always follows your Mac's default output device.")
                            .marginaliaTextStyle(.caption, in: scheme, ink: .inkSecondary)
                    }

                    Button("Refresh Devices", action: { Task { await viewModel.refreshAudioDevices() } })
                        .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                }
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)

            SettingsCard(title: "Audio Backend") {
                SettingsDisabledGroup(availability: viewModel.audioBackendAvailability) {
                    Picker(selection: audioBackendBinding) {
                        ForEach(AudioBackendOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            .padding(.horizontal, MarginaliaSpacing.md.value)
        }
    }

    // MARK: - Live bindings

    private var saveAudioRecordingsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.saveAudioRecordings },
            set: { newValue in Task { try? await viewModel.setSaveAudioRecordings(newValue) } }
        )
    }

    // MARK: - Honest-disabled bindings

    private var recordingStartNotificationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.recordingStartNotification },
            set: { newValue in Task { try? await viewModel.setRecordingStartNotification(newValue) } }
        )
    }

    private var micDeviceBinding: Binding<String?> {
        Binding(
            get: { viewModel.micDevice },
            set: { newValue in Task { try? await viewModel.setMicDevice(newValue) } }
        )
    }

    /// The only audio backend this app has ever captured through (`architecture.md`: a Core
    /// Audio process tap for system audio, cpal for the microphone) — a single real row, not a
    /// fabricated list of alternatives that don't exist yet.
    private enum AudioBackendOption: String, CaseIterable, Identifiable {
        case coreAudio

        var id: String {
            rawValue
        }

        var label: String {
            switch self {
            case .coreAudio: "Core Audio"
            }
        }
    }

    private var audioBackendBinding: Binding<AudioBackendOption> {
        Binding(
            get: { AudioBackendOption(rawValue: viewModel.audioBackend) ?? .coreAudio },
            set: { newValue in Task { try? await viewModel.setAudioBackend(newValue.rawValue) } }
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

    private var fileFormatCaption: String {
        "Saved as AAC-LC audio (.m4a), mono — matches the current capture pipeline."
    }
}
