//
//  CaptureCoordinatorTests.swift — Lane-1 coordinator suite (docs/plans/ari-recording-page.md
//  §6): synthetic source streams, no devices, no TCC. Windowing cadence, fork-before-mix,
//  mixed==AudioMixer parity, drop-oldest under a slow consumer, saver feed, and a playable
//  final .m4a.
//
#if os(macOS)
    import AriKit
    import AVFoundation
    import Foundation
    import Testing
    @testable import AriCapture

    @Suite("CaptureCoordinator (synthetic sources, Lane 1)")
    struct CaptureCoordinatorTests {
        private static let rate = Resampler.targetSampleRate

        /// A synthetic source: emits the given windows on start, finishes its stream on stop.
        private final class SyntheticSource: @unchecked Sendable {
            // Single-threaded test helper; accessed from one task at a time.
            private var continuation: AsyncStream<PCMWindow>.Continuation?
            private let windows: [PCMWindow]

            init(windows: [PCMWindow]) {
                self.windows = windows
            }

            func driver() -> CaptureCoordinator.SourceDriver {
                CaptureCoordinator.SourceDriver(
                    start: { [self] in
                        let (stream, continuation) = AsyncStream<PCMWindow>.makeStream(
                            bufferingPolicy: .unbounded
                        )
                        self.continuation = continuation
                        for window in windows {
                            continuation.yield(window)
                        }
                        return stream
                    },
                    stop: { [self] in
                        continuation?.finish()
                    },
                    availability: { .ready }
                )
            }
        }

        private static func windows(
            source: CaptureSource, value: Float, chunkSamples: Int, chunkCount: Int
        ) -> [PCMWindow] {
            (0 ..< chunkCount).map { index in
                PCMWindow(
                    samples: [Float](repeating: value, count: chunkSamples),
                    sampleRate: rate,
                    source: source,
                    hostTime: Double(index) * Double(chunkSamples) / rate,
                    windowID: UInt64(index)
                )
            }
        }

        private static func makeCoordinator(
            micWindows: [PCMWindow], systemWindows: [PCMWindow], folder: URL,
            windowDuration: Double = 0.6
        ) -> CaptureCoordinator {
            CaptureCoordinator(
                config: CaptureCoordinator.Config(
                    windowDuration: windowDuration,
                    meetingFolder: folder,
                    micEnabled: !micWindows.isEmpty,
                    systemEnabled: !systemWindows.isEmpty
                ),
                micDriver: micWindows.isEmpty ? nil : SyntheticSource(windows: micWindows).driver(),
                systemDriver: systemWindows.isEmpty ? nil : SyntheticSource(windows: systemWindows).driver()
            )
        }

        private static func tempFolder() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("capture-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @Test("~600 ms windowing: mixed windows carry windowDuration * 48k samples")
        func windowingCadence() async throws {
            let folder = try Self.tempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let windowSamples = Int(0.6 * Self.rate) // 28_800
            // 7 x 9_600 = 67_200 samples per source: 2 full windows (57_600) + a 9_600 tail.
            let mic = Self.windows(source: .microphone, value: 0.5, chunkSamples: 9600, chunkCount: 7)
            let system = Self.windows(source: .system, value: 0.25, chunkSamples: 9600, chunkCount: 7)
            let coordinator = Self.makeCoordinator(micWindows: mic, systemWindows: system, folder: folder)

            let collector = Task { await coordinator.mixedWindows().reduce(into: [PCMWindow]()) { $0.append($1) } }
            try await coordinator.start()
            _ = try await coordinator.finish()
            let mixed = await collector.value

            try #require(mixed.count == 3) // 2 full + 1 flushed tail
            #expect(mixed[0].samples.count == windowSamples)
            #expect(mixed[1].samples.count == windowSamples)
            #expect(mixed[2].samples.count == 9600 * 7 - windowSamples * 2)
            #expect(mixed.allSatisfy { $0.source == .mixed })
            #expect(mixed[1].hostTime == 0.6)
        }

        @Test("fork emits mic and system SEPARATELY, before mixing collapses them")
        func forkBeforeMix() async throws {
            let folder = try Self.tempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let mic = Self.windows(source: .microphone, value: 0.5, chunkSamples: 28800, chunkCount: 1)
            let system = Self.windows(source: .system, value: 0.25, chunkSamples: 28800, chunkCount: 1)
            let coordinator = Self.makeCoordinator(micWindows: mic, systemWindows: system, folder: folder)

            let forked = Task { await coordinator.forkedWindows().reduce(into: [PCMWindow]()) { $0.append($1) } }
            let mixed = Task { await coordinator.mixedWindows().reduce(into: [PCMWindow]()) { $0.append($1) } }
            try await coordinator.start()
            _ = try await coordinator.finish()

            let forkedWindows = await forked.value
            let mixedWindows = await mixed.value

            let micForks = forkedWindows.filter { $0.source == .microphone }
            let systemForks = forkedWindows.filter { $0.source == .system }
            #expect(!micForks.isEmpty && !systemForks.isEmpty)
            #expect(micForks.allSatisfy { $0.samples.allSatisfy { $0 == 0.5 } })
            #expect(systemForks.allSatisfy { $0.samples.allSatisfy { $0 == 0.25 } })

            // Mixed output equals AudioMixer's result on the same per-window inputs.
            let expected = AudioMixer().mix(
                mic: micForks[0].samples, system: systemForks[0].samples
            )
            #expect(mixedWindows[0].samples == expected)
        }

        @Test("a slow mixed-window consumer never stalls the producer (drop-oldest)")
        func dropOldestUnderSlowConsumer() async throws {
            let folder = try Self.tempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            // 40 full windows with NO subscribed consumer at all — the worst-case slow consumer.
            let mic = Self.windows(source: .microphone, value: 0.1, chunkSamples: 28800, chunkCount: 40)
            let coordinator = Self.makeCoordinator(micWindows: mic, systemWindows: [], folder: folder)

            let started = ContinuousClock.now
            try await coordinator.start()
            let url = try await coordinator.finish()
            let elapsed = ContinuousClock.now - started

            // Completing at all proves nothing blocked on the unconsumed streams; the bound is
            // generous headroom for CI machines, not a performance claim.
            #expect(elapsed < .seconds(30))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        @Test("mic-only: system contributes silence and the recording still saves")
        func micOnlyDegradedMode() async throws {
            let folder = try Self.tempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let mic = Self.windows(source: .microphone, value: 0.5, chunkSamples: 28800, chunkCount: 2)
            let coordinator = Self.makeCoordinator(micWindows: mic, systemWindows: [], folder: folder)

            let collector = Task { await coordinator.mixedWindows().reduce(into: [PCMWindow]()) { $0.append($1) } }
            try await coordinator.start()
            let status = await coordinator.sourceStatus()
            _ = try await coordinator.finish()
            let mixed = await collector.value

            #expect(status.mic == .ready)
            if case .unavailable = status.system {} else {
                Issue.record("system should be honestly unavailable, got \(status.system)")
            }
            // With system silent, mixed == mixer(mic, zeros) on every window.
            let expected = AudioMixer().mix(
                mic: mixed[0].samples.map { _ in Float(0.5) }, system: [Float](repeating: 0, count: mixed[0].samples.count)
            )
            #expect(mixed[0].samples == expected)
        }

        @Test("start throws honestly when no source starts at all")
        func noSourceStarts() async throws {
            let folder = try Self.tempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            struct DeadDeviceError: Error {}
            let dead = CaptureCoordinator.SourceDriver(
                start: { throw DeadDeviceError() },
                stop: {},
                availability: { .unavailable(reason: "dead") }
            )
            let coordinator = CaptureCoordinator(
                config: CaptureCoordinator.Config(
                    meetingFolder: folder, micEnabled: true, systemEnabled: true
                ),
                micDriver: dead,
                systemDriver: dead
            )
            await #expect(throws: CaptureCoordinatorError.self) {
                try await coordinator.start()
            }
        }

        @Test("finish() produces a real, decodable audio.m4a whose length matches the fed samples")
        func finalFileIsReal() async throws {
            let folder = try Self.tempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let totalSamples = 28800 * 2
            let mic = Self.windows(source: .microphone, value: 0.3, chunkSamples: 28800, chunkCount: 2)
            let coordinator = Self.makeCoordinator(micWindows: mic, systemWindows: [], folder: folder)

            try await coordinator.start()
            let url = try await coordinator.finish()

            #expect(url.lastPathComponent == "audio.m4a")
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let expected = Double(totalSamples) / Self.rate
            // AAC adds priming/remainder frames; assert within a small tolerance.
            #expect(abs(duration - expected) < 0.2)
        }
    }
#endif
