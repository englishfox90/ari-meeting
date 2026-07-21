//
//  SpeechVADTests.swift — Lane 1 (arikit-native-shell.md §7): segmentation on fixture
//  speech/silence probability sequences — min-length gate (800 samples), redemption across
//  natural pauses, honest-empty on too-short.
//
#if os(macOS)
    import Testing
    @testable import AriCapture

    @Suite("SpeechVADSegmenter")
    struct SpeechVADTests {
        /// One 30 ms @ 16 kHz analysis frame (480 samples) of arbitrary non-zero PCM — the
        /// segmenter doesn't inspect PCM content, only accumulates it, so the exact waveform is
        /// unimportant to these tests.
        private func frame(value: Float = 0.1, count: Int = 480) -> [Float] {
            [Float](repeating: value, count: count)
        }

        @Test("all-silence input never opens a segment; flush is an honest nil")
        func allSilenceProducesNoSegments() {
            let vad = SpeechVADSegmenter()
            for _ in 0 ..< 20 {
                #expect(vad.process(frame: frame(), probability: 0.05) == nil)
            }
            #expect(vad.flush() == nil)
        }

        @Test("a too-short speech burst is dropped honestly, not emitted as a tiny fragment")
        func tooShortBurstIsDropped() {
            // Small frames so the burst can close well under the 800-sample min-segment gate —
            // a single 480-sample analysis frame already exceeds the gate the moment one grace
            // frame is appended, so this test uses a smaller nominal frame size to reach an
            // actually-too-short total (mirrors the incumbent's tiny-fragment case, `vad.rs`
            // comment "Previous: 100ms allowed too-short fragments").
            var config = SpeechVADConfig()
            config.redemptionTimeMs = 6 // one 100-sample grace frame (6.25ms) already clears it
            let vad = SpeechVADSegmenter(config: config)

            // 100 samples of speech, then a single grace frame of silence — closes at
            // 200 total samples, well under the 800-sample min-segment gate.
            #expect(vad.process(frame: frame(count: 100), probability: 0.9) == nil)
            let closed = vad.process(frame: frame(count: 100), probability: 0.1)
            #expect(closed == nil, "200 samples < 800-sample min-segment gate must drop, not emit")
        }

        @Test("sustained speech clearing the min-segment gate is emitted on redemption close")
        func sustainedSpeechIsEmitted() throws {
            var config = SpeechVADConfig()
            config.redemptionTimeMs = 60
            let vad = SpeechVADSegmenter(config: config)

            // 4 frames of speech = 1920 samples, comfortably over the 800-sample gate.
            for _ in 0 ..< 4 {
                #expect(vad.process(frame: frame(), probability: 0.9) == nil)
            }
            _ = vad.process(frame: frame(), probability: 0.1) // 30ms below threshold — grace starts
            let segment = vad.process(frame: frame(), probability: 0.1) // 60ms — closes

            let closed = try #require(segment)
            #expect(closed.samples.count == 480 * 6) // 4 speech + 2 grace frames all accumulated
            #expect(closed.endTimestampMs > closed.startTimestampMs)
        }

        @Test("a brief dip under the negative threshold shorter than redemption bridges as ONE segment")
        func briefDipBridgesIntoOneSegment() throws {
            var config = SpeechVADConfig()
            config.redemptionTimeMs = 400 // needs 400ms (>13 frames) of sustained low probability
            let vad = SpeechVADSegmenter(config: config)

            for _ in 0 ..< 4 {
                #expect(vad.process(frame: frame(), probability: 0.9) == nil)
            }
            // One brief dip (30ms), well under the 400ms redemption window — must NOT close.
            #expect(vad.process(frame: frame(), probability: 0.1) == nil)
            // Speech resumes: the grace counter should have reset, not accumulated toward 400ms.
            for _ in 0 ..< 4 {
                #expect(vad.process(frame: frame(), probability: 0.9) == nil)
            }

            let flushed = try #require(vad.flush())
            // All 9 frames (4 + 1 dip + 4) ended up in the SAME segment — the pause never split it.
            #expect(flushed.samples.count == 480 * 9)
        }

        @Test("flush force-ends an open segment that clears the min-segment gate")
        func flushForceEndsOpenSegment() throws {
            let vad = SpeechVADSegmenter()
            for _ in 0 ..< 3 {
                #expect(vad.process(frame: frame(), probability: 0.9) == nil)
            }
            let flushed = try #require(vad.flush())
            #expect(flushed.samples.count == 480 * 3)
        }

        @Test("flush on a too-short open segment is an honest nil, not a fabricated stub")
        func flushOnTooShortSegmentIsHonestNil() {
            var config = SpeechVADConfig()
            config.minSegmentSamples = 800
            let vad = SpeechVADSegmenter(config: config)

            // One 480-sample frame — under the 800-sample gate.
            #expect(vad.process(frame: frame(), probability: 0.9) == nil)
            #expect(vad.flush() == nil)
        }
    }
#endif
