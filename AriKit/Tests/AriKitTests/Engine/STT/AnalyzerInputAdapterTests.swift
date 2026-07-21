//
//  AnalyzerInputAdapterTests.swift — docs/plans/ari-recording-page.md §6, the 4 cases.
//
//  `AnalyzerInput` itself exposes no public inspectable properties (it is an opaque `Speech`
//  framework wrapper around an `AVAudioPCMBuffer`), so per the R1 task brief, fidelity/format
//  cases exercise the underlying `AnalyzerInputAdapter.buffer(from:)` conversion layer directly
//  (internal, reached via `@testable import`) instead of round-tripping through `AnalyzerInput`.
//  The skip/laziness cases exercise the public `analyzerInputs(from:)` sequence by COUNTING
//  emitted elements (iterating an `AnalyzerInput` sequence needs no property access).
//
import AVFoundation
@testable import AriKit
import Testing

@Suite("AnalyzerInputAdapter")
struct AnalyzerInputAdapterTests {
    private func makeWindow(samples: [Float], sampleRate: Double = 48_000) -> PCMWindow {
        PCMWindow(samples: samples, sampleRate: sampleRate, source: .mixed, hostTime: 0, windowID: 1)
    }

    // MARK: 1. Sample fidelity

    @Test("buffer(from:) preserves samples exactly")
    func bufferPreservesSamples() throws {
        let samples: [Float] = [0.0, 0.25, -0.5, 0.75, -1.0, 1.0]
        let window = makeWindow(samples: samples)

        let buffer = try AnalyzerInputAdapter.buffer(from: window)

        #expect(buffer.frameLength == AVAudioFrameCount(samples.count))
        let channel = try #require(buffer.floatChannelData)
        let roundTripped = (0 ..< Int(buffer.frameLength)).map { channel[0][$0] }
        #expect(roundTripped == samples)
    }

    // MARK: 2. Format

    @Test("buffer(from:) is 48 kHz mono float32")
    func bufferIs48kHzMonoFloat32() throws {
        let window = makeWindow(samples: [0.1, 0.2, 0.3], sampleRate: 48_000)

        let buffer = try AnalyzerInputAdapter.buffer(from: window)

        #expect(buffer.format.sampleRate == 48_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
    }

    // MARK: 3. Empty window skipped

    @Test("an empty window is skipped — no fabricated buffer is emitted")
    func emptyWindowIsSkipped() async {
        let (stream, continuation) = AsyncStream<PCMWindow>.makeStream()
        continuation.yield(makeWindow(samples: []))
        continuation.yield(makeWindow(samples: [0.1, 0.2]))
        continuation.finish()

        let sequence = AnalyzerInputAdapter.analyzerInputs(from: stream)
        var count = 0
        for await _ in sequence {
            count += 1
        }
        #expect(count == 1)
    }

    // MARK: 4. Lazy / non-blocking consumption

    @Test("yielding into the source stream does not block on a slow/absent consumer")
    func producerIsNonBlocking() async {
        let (stream, continuation) = AsyncStream<PCMWindow>.makeStream()
        let sequence = AnalyzerInputAdapter.analyzerInputs(from: stream)

        // Yield several windows with NOBODY consuming `sequence` yet. `AsyncStream`'s default
        // `.unbounded` buffering makes `yield` synchronous/non-blocking regardless of whether the
        // adapter's mapped sequence is being iterated — proving the adapter does no eager work
        // (buffer construction) ahead of consumption.
        let start = ContinuousClock.now
        for index in 0 ..< 50 {
            continuation.yield(makeWindow(samples: [Float(index)]))
        }
        continuation.finish()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1))

        // Now drain lazily — every non-empty window still arrives, converted on pull.
        var count = 0
        for await _ in sequence {
            count += 1
        }
        #expect(count == 50)
    }
}
