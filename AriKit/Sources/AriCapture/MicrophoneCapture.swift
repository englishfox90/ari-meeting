//
//  MicrophoneCapture.swift — AVAudioEngine mic capture → 48 kHz mono f32
//  (docs/plans/ari-recording-page.md §2.1 R3, ← arikit-native-shell.md §4.2, ←
//  `frontend/src-tauri/src/audio/capture/microphone.rs` / `audio/stream.rs`'s cpal path,
//  coding-conventions.md "mic 16→48 kHz resample").
//
//  Reference-behavior, not transliterated: AVAudioEngine + AVAudioConverter replace cpal.
//  The two hard-won behavior facts preserved from the incumbent are (a) the tap MUST use the
//  hardware's own `inputNode.outputFormat(forBus:0)` — forcing a format crashes
//  (arikit-native-shell.md §4.2) — and (b) device churn (AirPods 16/24 kHz switches) is
//  recovered from in place via `AVAudioEngineConfigurationChange`, never by tearing down the
//  whole recording.
//
//  Lane 2 only (docs/plans/ari-recording-page.md §6): device capture + real TCC state cannot be
//  exercised from `swift test`. `RealtimeWindowEmitter` (shared with `SystemAudioTap`) carries
//  the one justified `@unchecked Sendable` exception for the realtime tap-block bridge.
//
#if os(macOS)
    import AriKit
    import AVFoundation
    import CoreAudio
    import Foundation
    import os

    public actor MicrophoneCapture {
        private static let logger = Logger(subsystem: "com.arivo.ari.AriCapture", category: "capture.microphone")

        /// Buffer size in frames for `installTap` — a few hundred ms of native-rate audio.
        /// `CaptureCoordinator` re-windows to the fixed ~600 ms cadence downstream, so this
        /// value only affects callback frequency, not the final window size.
        private static let tapBufferSize: AVAudioFrameCount = 4096

        private let engine = AVAudioEngine()
        private var emitter: RealtimeWindowEmitter?
        private var configChangeObserver: NSObjectProtocol?
        private var isRunning = false
        /// The persisted CoreAudio device UID to prefer, if any (settings-audio-devices.md §2.2).
        /// Set before `start()`; re-applied on every config-change rebuild since
        /// `installTapAndStart` is the shared path for both. Never cleared on a failed apply —
        /// an unplugged device falls back to system default this run, but a replug re-selects it
        /// on the next rebuild/recording (No-Fake-State: we never silently forget the user's choice).
        private var preferredDeviceUID: String?

        public init() {}

        /// Sets the microphone device to prefer at the next `installTapAndStart` (the next
        /// `start()` or config-change rebuild). `nil` = system default.
        public func setPreferredDeviceUID(_ uid: String?) {
            preferredDeviceUID = uid
        }

        /// Starts the engine and installs the input tap. Emitted windows are already resampled
        /// to 48 kHz mono (← `Resampler`, via `RealtimeWindowEmitter`).
        public func start() async throws -> AsyncStream<PCMWindow> {
            guard !isRunning else { throw MicrophoneCaptureError.alreadyRunning }

            let (stream, continuation) = AsyncStream<PCMWindow>.makeStream(bufferingPolicy: .bufferingNewest(8))
            let emitter = RealtimeWindowEmitter(source: .microphone, continuation: continuation)
            self.emitter = emitter

            try installTapAndStart(emitter: emitter)
            isRunning = true

            // Device churn (arikit-native-shell.md §4.2): stop → re-read the hardware format →
            // rebuild → restart, in place, so the recording continues. Handled entirely inside
            // this actor — `RecordingSession`/`CaptureCoordinator` observe nothing but a
            // transient gap in the stream.
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.handleConfigurationChange() }
            }

            return stream
        }

        public func stop() async {
            guard isRunning else { return }
            isRunning = false
            if let configChangeObserver {
                NotificationCenter.default.removeObserver(configChangeObserver)
                self.configChangeObserver = nil
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            emitter?.finish()
            emitter = nil
        }

        /// Honest readiness from real TCC state — never fabricated (No-Fake-State).
        public func availability() -> CaptureAvailability {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                .ready
            case .notDetermined:
                .notDetermined
            case .denied, .restricted:
                .unavailable(
                    reason: "Microphone access is denied. Enable it in System Settings > Privacy & Security > Microphone."
                )
            @unknown default:
                .unavailable(reason: "Microphone availability could not be determined.")
            }
        }

        /// Installs the tap at the hardware's own format (never a forced format — forcing
        /// crashes, arikit-native-shell.md §4.2) and starts the engine. Callable again after a
        /// configuration-change stop to rebuild against the fresh hardware format — which is
        /// also how a `preferredDeviceUID` set via `setPreferredDeviceUID` gets (re-)applied
        /// (settings-audio-devices.md §2.2 R2): `start()` and a config-change rebuild share this
        /// one path, so device binding "survives the rebuild" for free.
        ///
        /// Revised ordering (R2): the input/output AU is shared on this engine, so calling
        /// `setDeviceID` without a `reset()` + `prepare()` afterward leaves
        /// `outputFormat(forBus:0)` at 0 channels. `setDeviceID` therefore runs BEFORE
        /// `reset()`/`prepare()`, and the format is read only after both.
        private func installTapAndStart(emitter: RealtimeWindowEmitter) throws {
            let inputNode = engine.inputNode

            if let preferredDeviceUID {
                if let deviceID = CoreAudioDeviceEnumerator.resolveDeviceID(uid: preferredDeviceUID) {
                    if (try? inputNode.auAudioUnit.setDeviceID(deviceID)) == nil {
                        Self.logger
                            .notice(
                                "Could not select the preferred microphone device; falling back to the system default."
                            )
                    }
                } else {
                    // Unplugged (or a stale legacy device name, R4) — honest fallback, never an
                    // error, and the persisted UID is left untouched so a replug re-selects it.
                    Self.logger
                        .notice("Preferred microphone device is not currently attached; using the system default.")
                }
            }

            engine.reset()
            engine.prepare()

            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw MicrophoneCaptureError.noInputFormat
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return }

                let channelCount = Int(buffer.format.channelCount)
                let samples: [Float]
                if channelCount == 1 {
                    samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
                } else {
                    // Downmix to mono by averaging channels — the pipeline's mono contract
                    // (← `AACRecorder.decode`'s identical downmix for multi-channel files).
                    var mono = [Float](repeating: 0, count: frameLength)
                    for channel in 0 ..< channelCount {
                        let data = channelData[channel]
                        for index in 0 ..< frameLength {
                            mono[index] += data[index]
                        }
                    }
                    let divisor = Float(channelCount)
                    for index in 0 ..< frameLength {
                        mono[index] /= divisor
                    }
                    samples = mono
                }

                emitter.emit(samples: samples, sourceSampleRate: buffer.format.sampleRate)
            }

            engine.prepare()
            try engine.start()
        }

        private func handleConfigurationChange() async {
            guard isRunning, let emitter else { return }
            Self.logger.notice("Audio engine configuration changed; rebuilding the microphone tap")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            do {
                try installTapAndStart(emitter: emitter)
            } catch {
                Self.logger
                    .error(
                        "Could not rebuild microphone capture after a configuration change: \(String(describing: error), privacy: .public)"
                    )
                isRunning = false
                emitter.finish()
            }
        }
    }

    public enum MicrophoneCaptureError: Error, Equatable, Sendable {
        case alreadyRunning
        case noInputFormat
    }
#endif
