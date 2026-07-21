//
//  ResamplerTests.swift — Lane 1 (arikit-native-shell.md §7): AVAudioConverter 16→48 / 24→48 /
//  48→48 kHz mono correctness on fixture buffers (sample-count, no wild clipping).
//
#if os(macOS)
    import Foundation
    import Testing
    @testable import AriCapture

    @Suite("Resampler")
    struct ResamplerTests {
        let resampler = Resampler()

        /// A simple sine-wave fixture buffer — enough signal for AVAudioConverter to do real work,
        /// not silence.
        private func sineFixture(count: Int, sampleRate: Double, frequency: Double = 220) -> [Float] {
            (0 ..< count).map { index in
                let phase = 2.0 * Double.pi * frequency * Double(index) / sampleRate
                let amplitude = 0.5
                return Float(sin(phase) * amplitude)
            }
        }

        @Test("48 kHz → 48 kHz is a pass-through: identical samples, no conversion round trip")
        func fortyEightToFortyEightIsPassthrough() throws {
            let input = sineFixture(count: 4800, sampleRate: 48000)
            let output = try resampler.resample(input, from: 48000)
            #expect(output == input)
        }

        @Test("16 kHz → 48 kHz upsamples by ~3x and stays within range")
        func sixteenToFortyEightUpsamplesByThree() throws {
            let input = sineFixture(count: 1600, sampleRate: 16000) // 100 ms
            let output = try resampler.resample(input, from: 16000)

            let expectedCount = 4800 // 100 ms @ 48 kHz
            // AVAudioConverter's internal filter introduces a small, format-dependent latency/
            // priming offset — allow up to ~1.5ms (72 samples @ 48kHz) of drift rather than
            // asserting an exact ratio.
            #expect(abs(output.count - expectedCount) <= 72)
            #expect(output.allSatisfy { abs($0) <= 1.5 }) // small interpolation overshoot allowance
        }

        @Test("24 kHz → 48 kHz upsamples by 2x and stays within range")
        func twentyFourToFortyEightUpsamplesByTwo() throws {
            let input = sineFixture(count: 2400, sampleRate: 24000) // 100 ms
            let output = try resampler.resample(input, from: 24000)

            let expectedCount = 4800 // 100 ms @ 48 kHz
            #expect(abs(output.count - expectedCount) <= 32)
            #expect(output.allSatisfy { abs($0) <= 1.5 })
        }

        @Test("empty input resamples to an honest empty output, never fabricated samples")
        func emptyInputStaysEmpty() throws {
            let output = try resampler.resample([], from: 16000)
            #expect(output.isEmpty)
        }
    }
#endif
