//
//  AudioInputDevice.swift — a real, enumerable microphone (docs/plans/settings-audio-devices.md
//  §2.1). The shared seam type between `CoreAudioDeviceEnumerator` (below), `SettingsViewModel`
//  (picker list), and `MicrophoneCapture` (in `AriCapture`, which resolves a persisted `uid` back
//  to a live `AudioObjectID`).
//
//  Lives in `AriKit` (not `AriCapture`) so `AriViewModels` can depend on the seam type + the
//  `AudioDeviceProviding` protocol without gaining a forbidden `AriCapture` dependency — the same
//  `SpeechAssetProviding`/`SpeechAssetManager` precedent.
//

/// One real CoreAudio input device. `uid` is `kAudioDevicePropertyDeviceUID` — stable across
/// launches and reconnects (unlike an `AudioObjectID`, which is only valid for the device's
/// current attachment), so it's what gets persisted in `SettingsRepository`.
public struct AudioInputDevice: Sendable, Identifiable, Equatable {
    /// CoreAudio `kAudioDevicePropertyDeviceUID` — the stable identifier to persist.
    public let uid: String
    /// `kAudioObjectPropertyName` / `kAudioDevicePropertyDeviceNameCFString` — human display name.
    public let name: String

    public var id: String {
        uid
    }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}
