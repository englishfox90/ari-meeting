//
//  AACRecorderRoundTripTests.swift — Lane 1 (arikit-native-shell.md §7): encode fixture PCM →
//  `.m4a` → decode → PCM within tolerance; AAC-LC / 48 kHz mono settings assertion.
//
//  Headless: `AVAudioFile` read/write is plain file I/O, needs no signed bundle or TCC grant.
//
#if os(macOS)
    import AVFoundation
    import Foundation
    import Testing
    @testable import AriCapture

    @Suite("AACRecorder round trip")
    struct AACRecorderRoundTripTests {
        let recorder = AACRecorder()

        private func sineFixture(seconds: Double, sampleRate: Double = 48000, frequency: Double = 220) -> [Float] {
            let count = Int(seconds * sampleRate)
            return (0 ..< count).map { index in
                let phase = 2.0 * Double.pi * frequency * Double(index) / sampleRate
                let amplitude = 0.5
                return Float(sin(phase) * amplitude)
            }
        }

        private func temporaryFileURL() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("ari-capture-test-\(UUID().uuidString).m4a")
        }

        @Test("encode → decode round trip preserves duration within AAC-encoder tolerance")
        func roundTripPreservesDuration() throws {
            let input = sineFixture(seconds: 2)
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url) }

            try recorder.encode(samples: input, to: url)
            let (decoded, sampleRate) = try recorder.decode(from: url)

            #expect(sampleRate == AACRecorder.sampleRate)
            #expect(!decoded.isEmpty)

            // AAC-LC has encoder priming/flush samples, so exact sample-count equality is not
            // expected — allow ~50ms of drift at 48 kHz (2,400 samples).
            let expectedCount = input.count
            #expect(abs(decoded.count - expectedCount) <= 2400)
        }

        @Test("encoded file is mono at the pipeline's 48 kHz rate")
        func encodedFileIsMonoFortyEightKHz() throws {
            let input = sineFixture(seconds: 1)
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url) }

            try recorder.encode(samples: input, to: url)

            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == AACRecorder.sampleRate)
            #expect(file.fileFormat.channelCount == 1)
        }

        @Test("encoding empty samples throws an honest error, never writes a fabricated empty file")
        func emptyInputThrows() {
            let url = temporaryFileURL()
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(throws: AACRecorderError.noAudioData) {
                try recorder.encode(samples: [], to: url)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
#endif
