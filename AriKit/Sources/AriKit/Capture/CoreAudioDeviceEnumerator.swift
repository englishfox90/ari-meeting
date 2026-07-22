//
//  CoreAudioDeviceEnumerator.swift — the real `AudioDeviceProviding` conformer
//  (docs/plans/settings-audio-devices.md §2.1, R1).
//
//  Enumerates via the CoreAudio HAL (`kAudioHardwarePropertyDevices`), NOT
//  `AVCaptureDevice.DiscoverySession` — R1 found the DiscoverySession returns zero audio devices
//  on macOS 26. The HAL is the same recipe `SystemAudioTap` already uses for the default-output
//  device; the small property-reader helpers are intentionally duplicated here rather than
//  widening `SystemAudioTap`'s surface (plan §2.1).
//
//  Stateless `Sendable` struct; methods are `nonisolated async` so the synchronous HAL calls run
//  off the caller's (main) actor on the cooperative thread pool rather than blocking the UI.
//
import Foundation
#if os(macOS)
    import CoreAudio
#endif

/// The real, CoreAudio-HAL-backed `AudioDeviceProviding` conformer.
public struct CoreAudioDeviceEnumerator: AudioDeviceProviding, Sendable {
    public init() {}

    #if os(macOS)
        public func inputDevices() async -> [AudioInputDevice] {
            guard let deviceIDs = try? Self.allDeviceIDs() else { return [] }
            return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
                guard Self.hasInputChannels(deviceID) else { return nil }
                guard
                    let uid = try? Self.stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                    let name = try? Self.stringProperty(objectID: deviceID, selector: kAudioObjectPropertyName)
                else { return nil }
                return AudioInputDevice(uid: uid, name: name)
            }
        }

        public func defaultOutputDeviceName() async -> String? {
            guard let deviceID = try? Self.defaultOutputDeviceID() else { return nil }
            return try? Self.stringProperty(objectID: deviceID, selector: kAudioObjectPropertyName)
        }

        /// Resolves a persisted device UID to a currently-live `AudioObjectID`, or `nil` if the
        /// device isn't attached right now (unplugged) — the caller (`MicrophoneCapture`) treats
        /// `nil` as an honest "fall back to system default", never an error.
        public static func resolveDeviceID(uid: String) -> AudioObjectID? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidCF = uid as CFString
            var deviceID = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = withUnsafeMutablePointer(to: &uidCF) { uidPointer -> OSStatus in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    UInt32(MemoryLayout<CFString>.size),
                    uidPointer,
                    &size,
                    &deviceID
                )
            }
            guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
            return deviceID
        }

        // MARK: - HAL helpers (deliberately duplicated from `SystemAudioTap`, plan §2.1)

        private static func allDeviceIDs() throws -> [AudioObjectID] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
            )
            guard sizeStatus == noErr else { throw CoreAudioDeviceEnumeratorError.propertyReadFailed(sizeStatus) }

            let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            guard count > 0 else { return [] }
            var deviceIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
            )
            guard status == noErr else { throw CoreAudioDeviceEnumeratorError.propertyReadFailed(status) }
            return deviceIDs
        }

        private static func hasInputChannels(_ deviceID: AudioObjectID) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
            guard sizeStatus == noErr, dataSize > 0 else { return false }

            let bufferListPointer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { bufferListPointer.deallocate() }
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
            guard status == noErr else { return false }

            let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            return buffers.contains { $0.mNumberChannels > 0 }
        }

        private static func defaultOutputDeviceID() throws -> AudioObjectID {
            var deviceID = AudioObjectID(kAudioObjectUnknown)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
            )
            guard status == noErr else { throw CoreAudioDeviceEnumeratorError.propertyReadFailed(status) }
            return deviceID
        }

        /// Reads a `CFString`-typed property. `AudioObjectGetPropertyData` follows the CF "copy
        /// rule" for these despite the "Get" name — `Unmanaged.takeRetainedValue()` balances that
        /// ownership transfer without leaking (← `SystemAudioTap.stringProperty`).
        private static func stringProperty(
            objectID: AudioObjectID, selector: AudioObjectPropertySelector
        ) throws -> String {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var value: Unmanaged<CFString>?
            let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
                AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
            }
            guard status == noErr, let value else { throw CoreAudioDeviceEnumeratorError.propertyReadFailed(status) }
            return value.takeRetainedValue() as String
        }
    #else
        public func inputDevices() async -> [AudioInputDevice] {
            []
        }

        public func defaultOutputDeviceName() async -> String? {
            nil
        }

        public static func resolveDeviceID(uid _: String) -> UInt32? {
            nil
        }
    #endif
}

#if os(macOS)
    public enum CoreAudioDeviceEnumeratorError: Error, Equatable, Sendable {
        case propertyReadFailed(OSStatus)
    }
#endif
