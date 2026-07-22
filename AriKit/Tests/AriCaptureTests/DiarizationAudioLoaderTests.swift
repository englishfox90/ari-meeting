//
//  DiarizationAudioLoaderTests.swift — D6 (docs/plans/arikit-diarization.md §5): decode a
//  bundled fixture m4a to 16 kHz mono PCM; assert sample-count/rate, multi-channel downmix, and
//  an honest error on an unreadable file.
//
#if os(macOS)
    @testable import AriCapture
    import AriKit
    import Foundation
    import Testing

    @Suite("DiarizationAudioLoader")
    struct DiarizationAudioLoaderTests {
        let loader = DiarizationAudioLoader()

        /// 1 second, stereo, 44.1 kHz AAC — exercises both the sample-rate conversion (44.1 kHz
        /// → 16 kHz) and the channel downmix (stereo → mono) in one fixture. Deliberately
        /// asymmetric: the LEFT channel is SILENT and only the RIGHT channel carries a 330 Hz
        /// tone (see `Fixtures/generate_stereo_fixture.swift`). This makes the fixture a real
        /// downmix mutation-check: an implementation that discards every channel but the first
        /// (`AVAudioConverter`'s `downmix = false` default) decodes this fixture to silence,
        /// which `downmixesMultiChannelInput` below asserts against.
        private var stereoFixtureURL: URL {
            Bundle.module.url(forResource: "diarization-stereo-1s", withExtension: "m4a", subdirectory: "Fixtures")!
        }

        @Test("decodes a stereo 44.1 kHz fixture to ~16 kHz mono sample count")
        func decodesToExpectedSampleCountAndRate() async throws {
            let samples = try await loader.load16kMono(from: stereoFixtureURL)

            #expect(!samples.isEmpty)

            // 1 second of source audio at the 16 kHz target rate is ~16,000 samples. AAC
            // priming/remainder + converter filter state introduce drift, same as
            // `ResamplerTests`'s tolerance — allow ~100ms (1,600 samples) at 16 kHz.
            let expectedCount = Int(DiarizationAudioLoader.targetSampleRate)
            #expect(abs(samples.count - expectedCount) <= 1600)
        }

        @Test("downmixes multi-channel input to a single mono stream, not silence")
        func downmixesMultiChannelInput() async throws {
            let samples = try await loader.load16kMono(from: stereoFixtureURL)

            #expect(!samples.isEmpty)
            // The fixture's LEFT channel is silent and ONLY the RIGHT channel carries signal
            // (see `Fixtures/generate_stereo_fixture.swift`). A downmix implementation that
            // discards every channel but the first (`AVAudioConverter`'s default
            // `downmix = false`) maps output <- left channel and decodes to all-zero output —
            // this assertion fails against that implementation and passes only once the right
            // channel's energy genuinely survives the mono mix.
            let hasSignal = samples.contains { abs($0) > 0.01 }
            #expect(hasSignal)
            // All samples stay within the canonical float PCM range — never clipped/fabricated
            // out of range by the conversion.
            #expect(samples.allSatisfy { $0 >= -1.0 && $0 <= 1.0 })
        }

        @Test("an unreadable file throws an honest error, never a fabricated empty buffer")
        func unreadableFileThrowsHonestError() async {
            let missingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ari-diarization-loader-test-\(UUID().uuidString).m4a")

            await #expect(throws: DiarizationError.self) {
                _ = try await loader.load16kMono(from: missingURL)
            }
        }

        @Test("a corrupt/undecodable file throws an honest error, never a fabricated empty buffer")
        func corruptFileThrowsHonestError() async throws {
            let garbageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ari-diarization-loader-test-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: garbageURL) }

            // Not a valid audio container at all — exercises the `AVAudioFile(forReading:)`
            // throw branch (as opposed to the missing-file branch above, which never reaches
            // `AVAudioFile` construction).
            try Data("not a real m4a file, just garbage bytes".utf8).write(to: garbageURL)

            await #expect(throws: DiarizationError.self) {
                _ = try await loader.load16kMono(from: garbageURL)
            }
        }
    }
#endif
