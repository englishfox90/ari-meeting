//
//  SystemAudioTap.swift — Core Audio process tap → private aggregate device → IOProc
//  (docs/plans/ari-recording-page.md §2.1 R4, ← arikit-native-shell.md §4.1, behavior-verbatim
//  port of `frontend/src-tauri/src/audio/capture/core_audio.rs:91-145`).
//
//  CRITICAL — the echo fix (core_audio.rs:120-133), preserved byte-for-byte in intent: the
//  aggregate device descriptor below carries ONLY the tap in `kAudioAggregateDeviceTapListKey`.
//  It deliberately has NO `kAudioAggregateDeviceSubDeviceListKey`. The tap alone provides all
//  the system audio needed — also including the output device's sub-device list would
//  double-capture the same audio (the tap AND the device echoing it), which is exactly the bug
//  the Rust code's comment documents fixing. Do not "complete" this descriptor with a sub-device
//  list; that reintroduces the echo.
//
//  Mono global tap excluding no processes (← `with_mono_global_tap_excluding_processes(&[])`,
//  core_audio.rs:91): captures ONE mixed mono system stream — individual remote call
//  participants are not separable from this stream (Q3, `open-questions.md`); that is F1's
//  known ceiling, not a capture bug.
//
//  Lane 2 only (docs/plans/ari-recording-page.md §6): the tap/aggregate/IOProc graph needs a
//  real audio-capture TCC grant and cannot be exercised from `swift test`.
//
#if os(macOS)
    import AriKit
    import CoreAudio
    import Foundation
    import os

    public actor SystemAudioTap {
        private static let logger = Logger(subsystem: "com.arivo.ari.AriCapture", category: "capture.system")

        private var tapID: AudioObjectID?
        private var aggregateDeviceID: AudioObjectID?
        private var ioProcID: AudioDeviceIOProcID?
        private var emitter: RealtimeWindowEmitter?
        private var isRunning = false

        public init() {}

        public func start() async throws -> AsyncStream<PCMWindow> {
            guard !isRunning else { throw SystemAudioTapError.alreadyRunning }

            do {
                let stream = try buildAndStartGraph()
                isRunning = true
                return stream
            } catch {
                // Honest failure: tear down whatever partially succeeded rather than leaving a
                // half-alive tap/aggregate around — never a graph that looks started but isn't.
                teardown()
                throw error
            }
        }

        public func stop() async {
            guard isRunning else { return }
            isRunning = false
            teardown()
        }

        /// Honest readiness. CoreAudio has no pre-flight "is audio-capture allowed" query — the
        /// TCC prompt fires on first tap creation, and denial simply yields silence at the tap
        /// (mirrors `permissions.rs:18-24`). `.notDetermined` is therefore the only honest
        /// static answer before a `start()` attempt; the real outcome (including denial-shaped
        /// creation failures) surfaces from `start()` itself via `.unavailable(reason:)`.
        public func availability() -> CaptureAvailability {
            isRunning ? .ready : .notDetermined
        }

        // MARK: - Graph construction (core_audio.rs:56-296 port)

        private func buildAndStartGraph() throws -> AsyncStream<PCMWindow> {
            // Mono global tap, excluding no processes — byte-for-byte the Rust choice.
            let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted

            var newTapID = AudioObjectID(kAudioObjectUnknown)
            let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
            guard tapStatus == noErr else {
                throw SystemAudioTapError.tapCreationFailed(tapStatus)
            }
            tapID = newTapID

            let tapUID = try Self.stringProperty(objectID: newTapID, selector: kAudioTapPropertyUID)
            let tapFormat = try Self.streamDescription(objectID: newTapID, selector: kAudioTapPropertyFormat)
            let outputDeviceID = try Self.defaultOutputDeviceID()
            let outputUID = try Self.stringProperty(objectID: outputDeviceID, selector: kAudioDevicePropertyDeviceUID)

            // NOTE: no `kAudioAggregateDeviceSubDeviceListKey` — see the file header echo-fix
            // note. `kAudioAggregateDeviceMainSubDeviceKey` only anchors the aggregate's clock
            // to the real output device; it does not add it as an audio source.
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "ari-system-audio-tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapUID] as [String: Any]
                ]
            ]

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
            guard aggregateStatus == noErr else {
                throw SystemAudioTapError.aggregateDeviceCreationFailed(aggregateStatus)
            }
            aggregateDeviceID = newAggregateID

            let (stream, continuation) = AsyncStream<PCMWindow>.makeStream(bufferingPolicy: .bufferingNewest(8))
            let emitter = RealtimeWindowEmitter(source: .system, continuation: continuation)
            self.emitter = emitter

            // Sample-rate churn (arikit-native-shell.md §4.1: "the tap ASBD sample rate can
            // change on a default-output device switch"): `RealtimeWindowEmitter.emit` re-reads
            // the source rate it's handed on every callback (it doesn't cache one), so a mid-
            // recording default-output switch is honored automatically without extra plumbing
            // here — no explicit "current sample rate" tracking needed on this side.
            var newIOProcID: AudioDeviceIOProcID?
            let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(
                &newIOProcID, newAggregateID, nil
            ) { _, inputData, _, _, _ in
                let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                for buffer in bufferList {
                    guard let dataPointer = buffer.mData else { continue }
                    let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    guard frameCount > 0 else { continue }
                    let samples = Array(UnsafeBufferPointer(
                        start: dataPointer.assumingMemoryBound(to: Float.self),
                        count: frameCount
                    ))
                    emitter.emit(samples: samples, sourceSampleRate: tapFormat.mSampleRate)
                }
            }
            guard ioProcStatus == noErr, let ioProcID = newIOProcID else {
                throw SystemAudioTapError.ioProcCreationFailed(ioProcStatus)
            }
            self.ioProcID = ioProcID

            let startStatus = AudioDeviceStart(newAggregateID, ioProcID)
            guard startStatus == noErr else {
                throw SystemAudioTapError.deviceStartFailed(startStatus)
            }

            return stream
        }

        /// Teardown order per plan: stop device → destroy IOProc → destroy aggregate → destroy
        /// tap. Best-effort (the process is exiting or already failed) — errors are logged, not
        /// thrown, since a failed teardown mid-`stop()`/failure-recovery must not itself leave
        /// state stuck.
        private func teardown() {
            if let aggregateDeviceID, let ioProcID {
                let stopStatus = AudioDeviceStop(aggregateDeviceID, ioProcID)
                if stopStatus != noErr {
                    Self.logger.error("AudioDeviceStop failed: \(stopStatus)")
                }
                let destroyProcStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                if destroyProcStatus != noErr {
                    Self.logger.error("AudioDeviceDestroyIOProcID failed: \(destroyProcStatus)")
                }
            }
            ioProcID = nil

            if let aggregateDeviceID {
                let destroyAggregateStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                if destroyAggregateStatus != noErr {
                    Self.logger.error("AudioHardwareDestroyAggregateDevice failed: \(destroyAggregateStatus)")
                }
            }
            aggregateDeviceID = nil

            if let tapID {
                let destroyTapStatus = AudioHardwareDestroyProcessTap(tapID)
                if destroyTapStatus != noErr {
                    Self.logger.error("AudioHardwareDestroyProcessTap failed: \(destroyTapStatus)")
                }
            }
            tapID = nil

            emitter?.finish()
            emitter = nil
        }

        // MARK: - Core Audio property helpers

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
            guard status == noErr else { throw SystemAudioTapError.propertyReadFailed(status) }
            return deviceID
        }

        /// Reads a `CFString`-typed property. `AudioObjectGetPropertyData` follows the CF "copy
        /// rule" for these despite the "Get" name (AudioHardwareBase.h: "the caller is
        /// responsible for releasing the returned CFObject") — `Unmanaged.takeRetainedValue()`
        /// balances that ownership transfer without leaking.
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
            guard status == noErr, let value else { throw SystemAudioTapError.propertyReadFailed(status) }
            return value.takeRetainedValue() as String
        }

        private static func streamDescription(
            objectID: AudioObjectID, selector: AudioObjectPropertySelector
        ) throws -> AudioStreamBasicDescription {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var value = AudioStreamBasicDescription()
            let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
            guard status == noErr else { throw SystemAudioTapError.propertyReadFailed(status) }
            return value
        }
    }

    public enum SystemAudioTapError: Error, Equatable, Sendable {
        case alreadyRunning
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case propertyReadFailed(OSStatus)
    }
#endif
