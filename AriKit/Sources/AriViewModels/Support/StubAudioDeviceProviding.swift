//
//  StubAudioDeviceProviding.swift — deterministic test double for the audio-device-enumeration
//  seam (docs/plans/settings-audio-devices.md §5 Lane 1).
//
//  Lets headless `swift test` drive `SettingsViewModel`'s device surface without touching real
//  CoreAudio HAL state — mirrors `StubSpeechAssetProviding`. Configurable so a test can assert
//  the populated-list and honestly-empty paths.
//
#if DEBUG
    import AriKit
    import Foundation

    public struct StubAudioDeviceProviding: AudioDeviceProviding {
        public let devices: [AudioInputDevice]
        public let outputName: String?

        public init(
            devices: [AudioInputDevice] = [],
            outputName: String? = nil
        ) {
            self.devices = devices
            self.outputName = outputName
        }

        public func inputDevices() async -> [AudioInputDevice] {
            devices
        }

        public func defaultOutputDeviceName() async -> String? {
            outputName
        }
    }
#endif
