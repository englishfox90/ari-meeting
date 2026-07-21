//
//  CaptureCoordinator.swift — the Swift analog of `AudioPipeline::run()`
//  (docs/plans/ari-recording-page.md §2.1 R5, ← arikit-native-shell.md §4.3, behavior reference
//  `frontend/src-tauri/src/audio/pipeline.rs:824-895` — reference, never transliterated).
//
//  Owns: per-source accumulation → fixed ~600 ms windowing → the pre-mix PCM fork (the Q2/F1
//  seam: mic + system still SEPARATE) → mixing (`AudioMixer`) → the mixed stream for STT →
//  peak-hold live level → feeding `IncrementalSaver` off the hot path.
//
//  Hot-path discipline (Q2): the window loop never awaits STT, disk, or the DB. Consumers get
//  drop-oldest `AsyncStream`s (`.bufferingNewest`) — a slow consumer can never stall windowing;
//  a dropped window is real silence for that consumer and is logged honestly, never invented
//  audio. The saver runs as its own task fed by a bounded stream for the same reason.
//
//  Lane-1 testability: the coordinator is written against `SourceDriver` (start/stop/availability
//  closures), so tests drive it with synthetic streams and no devices; the public init wires the
//  real `MicrophoneCapture`/`SystemAudioTap` actors into drivers.
//
#if os(macOS)
    import AriKit
    import Foundation
    import os

    public actor CaptureCoordinator {
        private static let logger = Logger(subsystem: "com.arivo.ari.AriCapture", category: "capture.coordinator")

        public struct Config: Sendable {
            /// Window cadence in seconds (~600 ms, ← `pipeline.rs`).
            public var windowDuration: Double
            /// The meeting folder; `.checkpoints/` is created inside it before the saver starts.
            public var meetingFolder: URL
            public var micEnabled: Bool
            public var systemEnabled: Bool

            public init(
                windowDuration: Double = 0.6,
                meetingFolder: URL,
                micEnabled: Bool = true,
                systemEnabled: Bool = true
            ) {
                self.windowDuration = windowDuration
                self.meetingFolder = meetingFolder
                self.micEnabled = micEnabled
                self.systemEnabled = systemEnabled
            }
        }

        /// The Lane-1 seam: everything the coordinator needs from a capture device, as closures.
        /// The public init builds drivers over the real actors; tests build them over synthetic
        /// `AsyncStream`s.
        struct SourceDriver: Sendable {
            let start: @Sendable () async throws -> AsyncStream<PCMWindow>
            let stop: @Sendable () async -> Void
            let availability: @Sendable () async -> CaptureAvailability
        }

        private let config: Config
        private let micDriver: SourceDriver?
        private let systemDriver: SourceDriver?
        private let mixer = AudioMixer()
        private let recorder = AACRecorder()

        private var saver: IncrementalSaver?
        private var micStatus: CaptureAvailability = .notDetermined
        private var systemStatus: CaptureAvailability = .notDetermined

        // Per-source accumulation buffers (48 kHz mono — the emitters resample upstream).
        private var micBuffer: [Float] = []
        private var systemBuffer: [Float] = []
        private var micLive = false
        private var systemLive = false

        private var windowID: UInt64 = 0
        private var emittedWindows = 0

        private var consumerTasks: [Task<Void, Never>] = []
        private var saverTask: Task<Void, Never>?

        private var mixedContinuation: AsyncStream<PCMWindow>.Continuation?
        private var forkedContinuation: AsyncStream<PCMWindow>.Continuation?
        private var levelContinuation: AsyncStream<Float>.Continuation?
        private var saverContinuation: AsyncStream<[Float]>.Continuation?

        private var mixedStream: AsyncStream<PCMWindow>
        private var forkedStream: AsyncStream<PCMWindow>
        private var levelStream: AsyncStream<Float>

        private var isRunning = false
        private var isFinished = false

        /// Wires the real device actors.
        public init(config: Config, microphone: MicrophoneCapture, systemTap: SystemAudioTap) {
            self.init(
                config: config,
                micDriver: config.micEnabled ? SourceDriver(
                    start: { try await microphone.start() },
                    stop: { await microphone.stop() },
                    availability: { await microphone.availability() }
                ) : nil,
                systemDriver: config.systemEnabled ? SourceDriver(
                    start: { try await systemTap.start() },
                    stop: { await systemTap.stop() },
                    availability: { await systemTap.availability() }
                ) : nil
            )
        }

        /// The Lane-1 seam init (tests; also the public init's funnel).
        init(config: Config, micDriver: SourceDriver?, systemDriver: SourceDriver?) {
            self.config = config
            self.micDriver = config.micEnabled ? micDriver : nil
            self.systemDriver = config.systemEnabled ? systemDriver : nil

            // Streams exist from construction so consumers can subscribe before `start()`.
            let (mixed, mixedCont) = AsyncStream<PCMWindow>.makeStream(bufferingPolicy: .bufferingNewest(16))
            let (forked, forkedCont) = AsyncStream<PCMWindow>.makeStream(bufferingPolicy: .bufferingNewest(32))
            let (level, levelCont) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(4))
            mixedStream = mixed
            forkedStream = forked
            levelStream = level
            mixedContinuation = mixedCont
            forkedContinuation = forkedCont
            levelContinuation = levelCont
        }

        // MARK: - Lifecycle

        /// Starts the enabled devices + the saver. Throws honestly only if NO enabled source
        /// starts; a single-source failure is recorded in `sourceStatus()` for the banner.
        public func start() async throws {
            guard !isRunning, !isFinished else { throw CaptureCoordinatorError.alreadyStarted }

            // `.checkpoints/` must exist before `IncrementalSaver.init` (its documented contract).
            let checkpoints = config.meetingFolder.appendingPathComponent(".checkpoints", isDirectory: true)
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
            let saver = try IncrementalSaver(
                meetingFolder: config.meetingFolder,
                config: IncrementalSaverConfig(sampleRate: Resampler.targetSampleRate)
            )
            self.saver = saver

            var startedStreams: [(CaptureSource, AsyncStream<PCMWindow>)] = []

            if let micDriver {
                do {
                    let stream = try await micDriver.start()
                    micStatus = await micDriver.availability()
                    micLive = true
                    startedStreams.append((.microphone, stream))
                } catch {
                    micStatus = .unavailable(reason: "Microphone capture failed to start: \(error)")
                    Self.logger.error("Microphone start failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                micStatus = .unavailable(reason: "Microphone capture is turned off for this recording.")
            }

            if let systemDriver {
                do {
                    let stream = try await systemDriver.start()
                    systemStatus = await systemDriver.availability()
                    systemLive = true
                    startedStreams.append((.system, stream))
                } catch {
                    systemStatus = .unavailable(reason: "System audio capture failed to start: \(error)")
                    Self.logger.error("System tap start failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                systemStatus = .unavailable(reason: "System audio capture is turned off for this recording.")
            }

            guard !startedStreams.isEmpty else {
                self.saver = nil
                throw CaptureCoordinatorError.noSourceStarted(mic: micStatus, system: systemStatus)
            }

            // Saver feed: its own bounded lane so a slow checkpoint encode can never stall
            // windowing. A drop here is real data loss and is logged honestly (expected
            // unreachable at 30 s checkpoint cadence).
            let (saverStream, saverCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(64))
            saverContinuation = saverCont
            saverTask = Task {
                for await samples in saverStream {
                    do {
                        try await saver.addSamples(samples)
                    } catch {
                        Self.logger.error("Checkpoint write failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }

            for (source, stream) in startedStreams {
                consumerTasks.append(Task { [weak self] in
                    for await window in stream {
                        await self?.ingest(window)
                    }
                    await self?.sourceEnded(source)
                })
            }

            isRunning = true
        }

        /// Stops devices, drains buffers (final partial window included), flushes the saver,
        /// and remuxes checkpoints into the final `audio.m4a`.
        public func finish() async throws -> URL {
            guard isRunning, !isFinished else { throw CaptureCoordinatorError.notRunning }
            isFinished = true
            isRunning = false

            if let micDriver { await micDriver.stop() }
            if let systemDriver { await systemDriver.stop() }

            // Device streams finish on stop; wait for the consumers to drain what was emitted.
            for task in consumerTasks { await task.value }
            consumerTasks = []

            // Flush every remaining full window, then one final partial window (real tail audio
            // — losing it silently would be dishonest).
            drainReadyWindows()
            flushPartialTail()

            mixedContinuation?.finish()
            forkedContinuation?.finish()
            levelContinuation?.finish()
            saverContinuation?.finish()
            if let saverTask { await saverTask.value }

            guard let saver else { throw CaptureCoordinatorError.notRunning }
            return try await saver.finalize(outputFilename: "audio.m4a")
        }

        // MARK: - Streams

        public func mixedWindows() -> AsyncStream<PCMWindow> { mixedStream }
        public func forkedWindows() -> AsyncStream<PCMWindow> { forkedStream }
        public func liveLevel() -> AsyncStream<Float> { levelStream }

        public func sourceStatus() -> (mic: CaptureAvailability, system: CaptureAvailability) {
            (micStatus, systemStatus)
        }

        // MARK: - Windowing (the hot loop — no awaits on STT/disk/DB)

        private var windowSampleCount: Int {
            Int(config.windowDuration * Resampler.targetSampleRate)
        }

        private func ingest(_ window: PCMWindow) {
            switch window.source {
            case .microphone: micBuffer.append(contentsOf: window.samples)
            case .system: systemBuffer.append(contentsOf: window.samples)
            case .mixed: return // devices never emit .mixed; ignore rather than corrupt state
            }
            drainReadyWindows()
        }

        /// A source stream ending while the recording is still running means that device died
        /// mid-recording — surface it honestly in `sourceStatus()` (review finding M4) instead
        /// of leaving a green readout over a dead source. During `finish()` (`isRunning` already
        /// false) an ending stream is just normal teardown.
        private func sourceEnded(_ source: CaptureSource) {
            switch source {
            case .microphone:
                micLive = false
                if isRunning {
                    micStatus = .unavailable(reason: "The microphone stopped delivering audio mid-recording.")
                }
            case .system:
                systemLive = false
                if isRunning {
                    systemStatus = .unavailable(reason: "System audio stopped delivering mid-recording.")
                }
            case .mixed: break
            }
        }

        /// Emits every complete ~600 ms window. A window is ready when every LIVE source has a
        /// full window buffered; a non-live source contributes silence (zeros) — honest, since
        /// that source genuinely produced nothing.
        private func drainReadyWindows() {
            let count = windowSampleCount
            guard count > 0 else { return }
            while true {
                let micReady = !micLive || micBuffer.count >= count
                let systemReady = !systemLive || systemBuffer.count >= count
                let anyData = micBuffer.count >= count || systemBuffer.count >= count
                guard micReady, systemReady, anyData else { return }

                let mic = take(count, from: &micBuffer)
                let system = take(count, from: &systemBuffer)
                emitWindow(mic: mic, system: system, sampleCount: count)
            }
        }

        /// The end-of-recording tail: whatever partial audio remains in either buffer.
        private func flushPartialTail() {
            let remaining = max(micBuffer.count, systemBuffer.count)
            guard remaining > 0 else { return }
            let mic = take(remaining, from: &micBuffer)
            let system = take(remaining, from: &systemBuffer)
            emitWindow(mic: mic, system: system, sampleCount: remaining)
        }

        private func take(_ count: Int, from buffer: inout [Float]) -> [Float] {
            if buffer.isEmpty {
                return [Float](repeating: 0, count: count)
            }
            if buffer.count >= count {
                let slice = Array(buffer.prefix(count))
                buffer.removeFirst(count)
                return slice
            }
            var padded = buffer
            padded.append(contentsOf: [Float](repeating: 0, count: count - buffer.count))
            buffer.removeAll(keepingCapacity: true)
            return padded
        }

        private func emitWindow(mic: [Float], system: [Float], sampleCount: Int) {
            let hostTime = Double(emittedWindows) * config.windowDuration
            emittedWindows += 1

            // The pre-mix fork FIRST — mic + system still separate (the Q2/F1 seam).
            yieldForked(samples: mic, source: .microphone, hostTime: hostTime)
            yieldForked(samples: system, source: .system, hostTime: hostTime)

            let mixed = mixer.mix(mic: mic, system: system)
            let mixedWindow = PCMWindow(
                samples: mixed,
                sampleRate: Resampler.targetSampleRate,
                source: .mixed,
                hostTime: hostTime,
                windowID: nextWindowID()
            )
            if case let .dropped(dropped) = mixedContinuation?.yield(mixedWindow) ?? .terminated {
                Self.logger
                    .warning("Dropped mixed window \(dropped.windowID) — the STT consumer is behind; that window is silence to it")
            }

            let peak = mixed.reduce(into: Float(0)) { $0 = max($0, abs($1)) }
            levelContinuation?.yield(peak)

            if case .dropped = saverContinuation?.yield(mixed) ?? .terminated {
                Self.logger.error("Dropped a save window — audio data was lost before checkpointing")
            }
        }

        private func yieldForked(samples: [Float], source: CaptureSource, hostTime: Double) {
            let window = PCMWindow(
                samples: samples,
                sampleRate: Resampler.targetSampleRate,
                source: source,
                hostTime: hostTime,
                windowID: nextWindowID()
            )
            forkedContinuation?.yield(window)
        }

        private func nextWindowID() -> UInt64 {
            defer { windowID += 1 }
            return windowID
        }
    }

    public enum CaptureCoordinatorError: Error, Sendable {
        case alreadyStarted
        case notRunning
        case noSourceStarted(mic: CaptureAvailability, system: CaptureAvailability)
    }
#endif
