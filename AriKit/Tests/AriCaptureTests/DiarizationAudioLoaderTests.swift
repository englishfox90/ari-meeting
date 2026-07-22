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
        /// → 16 kHz) and the channel downmix (stereo → mono) in one fixture.
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
            // The fixture is a real (non-silent) two-tone signal; a broken downmix that
            // cancelled the channels or returned only one channel's worth of frames would
            // still be non-empty, so also assert genuine signal energy survived the mix.
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
    }
#endif
