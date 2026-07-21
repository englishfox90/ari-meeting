//
//  AudioMixerTests.swift — Lane 1 (arikit-native-shell.md §7): two-window mix = expected sum,
//  no post-gain, silence-system decays cleanly (mixes to exactly the mic signal).
//
#if os(macOS)
    import Testing
    @testable import AriCapture

    @Suite("AudioMixer")
    struct AudioMixerTests {
        let mixer = AudioMixer()

        @Test("mixes two non-clipping windows as a simple sum")
        func mixesAsSum() {
            let mic: [Float] = [0.1, 0.2, -0.1, 0.0]
            let system: [Float] = [0.05, -0.05, 0.05, 0.0]
            let mixed = mixer.mix(mic: mic, system: system)

            #expect(mixed.count == mic.count)
            for index in 0 ..< mic.count {
                let expected = mic[index] + system[index]
                #expect(abs(mixed[index] - expected) < 0.0001)
            }
        }

        @Test("silent system track decays cleanly to just the mic signal")
        func silentSystemPassesMicThrough() {
            let mic: [Float] = [0.3, -0.4, 0.25, 0.0, -0.1]
            let system = [Float](repeating: 0, count: mic.count)
            let mixed = mixer.mix(mic: mic, system: system)

            #expect(mixed == mic)
        }

        @Test("applies no post-gain — a full-scale mic-only window is unchanged")
        func noPostGainOnMicOnly() {
            let mic: [Float] = [1.0, -1.0, 0.5]
            let mixed = mixer.mix(mic: mic, system: [])

            #expect(mixed == mic)
        }

        @Test("soft-scales an over-range sum instead of hard-clipping")
        func softScalesClipping() {
            let mic: [Float] = [1.0, -1.0]
            let system: [Float] = [1.0, -1.0]
            let mixed = mixer.mix(mic: mic, system: system)

            // Sum is ±2.0; soft scaling divides by |sum| to land exactly at ±1.0, preserving sign,
            // rather than a fabricated intermediate value.
            #expect(mixed == [1.0, -1.0])
        }

        @Test("shorter window is zero-padded, never fabricated")
        func shorterWindowIsZeroPadded() {
            let mic: [Float] = [0.2, 0.2, 0.2]
            let system: [Float] = [0.1]
            let mixed = mixer.mix(mic: mic, system: system)

            #expect(mixed.count == 3)
            #expect(abs(mixed[0] - 0.3) < 0.0001)
            #expect(abs(mixed[1] - 0.2) < 0.0001)
            #expect(abs(mixed[2] - 0.2) < 0.0001)
        }

        @Test("two empty inputs mix to an honest empty window, not fabricated silence")
        func emptyInputsMixToEmpty() {
            #expect(mixer.mix(mic: [], system: []).isEmpty)
        }
    }
#endif
