//
//  FluidAudioDiarizationProviderTests.swift — D7 (docs/plans/arikit-diarization.md §5):
//  `FluidAudioDiarizationProvider` actor contract. `prepareIsIdempotentAcrossRepeatedCalls`
//  downloads/compiles the real ~21 MB FluidAudio community-1 CoreML models (network required,
//  cached after the first run) — swift-H1: asserts the actor's lazy-prepare contract holds
//  whether or not `prepare()` was called explicitly. The full-pipeline test below is separately
//  gated opt-in (see `Fixtures/README.md`).
//
#if os(macOS)
    @testable import AriKitDiarizationFluidAudio
    import AriKit
    import Foundation
    import Testing

    @Suite("FluidAudioDiarizationProvider")
    struct FluidAudioDiarizationProviderTests {
        @Test("prepareIsIdempotentAcrossRepeatedCalls")
        func prepareIsIdempotentAcrossRepeatedCalls() async throws {
            let explicit = FluidAudioDiarizationProvider()
            #expect(await explicit.isAvailable())

            try await explicit.prepare()
            // A second explicit prepare() is a no-op once already prepared — must not throw,
            // must not re-download/re-compile.
            try await explicit.prepare()

            // The protocol's honesty contract ("prepare() idempotent") must also hold for a
            // caller that skips the explicit prepare() step: diarize() lazy-prepares itself.
            // A silent clip has no speech to diarize, so `diarize()` is expected to fail on
            // content (`.providerFailed`, FluidAudio's `noSpeechDetected`) — what this asserts
            // is that it does NOT fail with `.modelsUnavailable`, i.e. the lazy model load
            // itself succeeded before content processing ran.
            let lazy = FluidAudioDiarizationProvider()
            let silence = [Float](repeating: 0, count: 16_000)
            do {
                _ = try await lazy.diarize(samples: silence, hint: .exact(1), progress: nil)
            } catch let error as DiarizationError {
                guard case .providerFailed = error else {
                    Issue.record("lazy diarize() failed before content processing: \(error)")
                    return
                }
            }
            // Now an explicit prepare() after the lazy path is also a no-op.
            try await lazy.prepare()
        }

        /// Manual/opt-in (plan §5 D7): requires the real model download AND a bundled two-voice
        /// fixture not present in this checkout — see `Fixtures/README.md`. Skipped by default.
        @Test(
            "twoVoiceFixtureYieldsAtLeastTwoClusters",
            .enabled(if: FluidAudioDiarizationProviderTests.integrationFixtureIsAvailable)
        )
        func twoVoiceFixtureYieldsAtLeastTwoClusters() async throws {
            let url = try #require(
                Bundle.module.url(forResource: "diarization-two-voices", withExtension: "wav", subdirectory: "Fixtures")
            )
            let samples = try Self.loadWAV16kMono(at: url)

            let provider = FluidAudioDiarizationProvider()
            let output = try await provider.diarize(samples: samples, hint: .exact(2), progress: nil)

            #expect(output.clusters.count >= 2)
        }

        private static var integrationFixtureIsAvailable: Bool {
            guard ProcessInfo.processInfo.environment["ARIKIT_DIARIZATION_INTEGRATION"] == "1" else {
                return false
            }
            return Bundle.module.url(
                forResource: "diarization-two-voices", withExtension: "wav", subdirectory: "Fixtures"
            ) != nil
        }

        private static func loadWAV16kMono(at url: URL) throws -> [Float] {
            let data = try Data(contentsOf: url)
            // Minimal 16-bit PCM WAV reader — the fixture is pre-decoded to 16 kHz mono, same
            // convention as `spikes/fluidaudio-s3`'s loader.
            guard data.count > 44 else { return [] }
            let pcmData = data.subdata(in: 44 ..< data.count)
            let sampleCount = pcmData.count / 2
            var samples = [Float](repeating: 0, count: sampleCount)
            pcmData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let int16Buffer = raw.bindMemory(to: Int16.self)
                for i in 0 ..< sampleCount {
                    samples[i] = Float(Int16(littleEndian: int16Buffer[i])) / 32768.0
                }
            }
            return samples
        }
    }
#endif
