//
//  SettingsRecordingsSection.swift — Recordings settings (docs/plans/settings-ui.md §6).
//
//  Save-audio toggle is LIVE (persists via `SettingsViewModel`). The save-location row is LIVE:
//  it resolves the real on-disk recordings folder (mirroring `AppEnvironment`'s own Application
//  Support layout, same recipe as `SettingsGeneralSection`) and opens it in Finder — never a
//  fabricated path. The file-format caption is LIVE informational copy matching the real
//  capture format (`AriCapture/AACRecorder.swift`: AAC-LC `.m4a`, mono). The "Ask for consent
//  before recording" toggle is LIVE (default OFF): it persists via the VM and is mirrored onto the
//  live `RecordingSession.requireConsent`. Recording-start alerts live in General ▸ Notifications
//  ("Recording alerts"), the single control for that notification — not duplicated here.
//
//  Microphone device selection is LIVE (docs/plans/settings-audio-devices.md): real CoreAudio
//  HAL enumeration via `CoreAudioDeviceEnumerator`, persisting a stable device UID that binds
//  into `MicrophoneCapture` at recording start. System audio is an honest READ-ONLY row (not a
//  picker) — `SystemAudioTap` is a single global Core Audio process tap anchored to the default
//  output device, so a per-device system-audio selection could never take effect. There is no
//  Audio Backend control: Core Audio is the only capture backend on Apple, so there was never a
//  second option to offer.
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

            VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
                SettingsGroup(header: "Audio") {
                    SettingsToggleRow(
                        "Save audio recordings",
                        description: "Keep the recorded audio file alongside the transcript.",
                        isOn: saveAudioRecordingsBinding
                    )
                    SettingsToggleRow(
                        "Ask for consent before recording",
                        description: "Show a quick confirmation before capture begins. Off by "
                            + "default — the Record button is itself the go-ahead. Turn on for "
                            + "two-party-consent situations.",
                        isOn: requireConsentBinding
                    )
                }

                SettingsGroup(header: "Save location", footnote: fileFormatCaption) {
                    VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                        Text(recordingsFolderDisplayPath)
                            .marginaliaTextStyle(.callout, in: scheme, ink: .inkSecondary)
                        Button("Open Folder", action: openRecordingsFolder)
                            .buttonStyle(.marginalia(.secondary, .regular, in: scheme))
                            .disabled(recordingsFolderURL == nil)
                    }
                    .settingsRowInsets()
                }

                SettingsGroup(
                    header: "Default devices",
                    footnote: "System audio always follows your Mac's default output device."
                ) {
                    SettingsRow("Microphone") {
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
                            Text("Microphone")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }

                    SettingsRow("System audio") {
                        Text(viewModel.defaultOutputDeviceName ?? "Current output device unavailable")
                            .marginaliaTextStyle(.body, in: scheme, ink: .inkSecondary)
                    }

                    HStack {
                        Spacer(minLength: 0)
                        Button("Refresh Devices", action: { Task { await viewModel.refreshAudioDevices() } })
                            .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
                    }
                    .settingsRowInsets()
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

    /// The consent-before-record preference (default OFF). Persisted via the VM, which also mirrors
    /// it onto the live `RecordingSession` so it takes effect immediately.
    private var requireConsentBinding: Binding<Bool> {
        Binding(
            get: { viewModel.recordingRequireConsent },
            set: { newValue in Task { try? await viewModel.setRecordingRequireConsent(newValue) } }
        )
    }

    private var micDeviceBinding: Binding<String?> {
        Binding(
            get: { viewModel.micDevice },
            set: { newValue in Task { try? await viewModel.setMicDevice(newValue) } }
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
