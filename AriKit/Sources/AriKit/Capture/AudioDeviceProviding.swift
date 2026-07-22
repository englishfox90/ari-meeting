//
//  AudioDeviceProviding.swift — the injectable audio-device-enumeration seam
//  (docs/plans/settings-audio-devices.md §2.1), mirroring `SpeechAssetProviding`.
//
//  Lets `SettingsViewModel` depend on an ABSTRACTION instead of the concrete
//  `CoreAudioDeviceEnumerator`, so headless tests inject a deterministic double and never touch
//  real CoreAudio HAL state. Production wires the real `CoreAudioDeviceEnumerator`, which conforms
//  below.
//

/// Real input-device enumeration + the current default output device's display name, abstracted
/// so callers (and tests) don't bind to the concrete CoreAudio-backed implementation.
public protocol AudioDeviceProviding: Sendable {
    /// Real input devices, stable UID + display name. Honest empty on failure/none — never a
    /// fabricated device entry (No-Fake-State).
    func inputDevices() async -> [AudioInputDevice]
    /// Human name of the current default OUTPUT device (what `SystemAudioTap` always follows),
    /// or `nil` if unresolved. Honestly absent rather than a fabricated placeholder.
    func defaultOutputDeviceName() async -> String?
}
