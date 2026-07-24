//
//  PeakLevelMeterTests.swift — Lane 1: gain, clamp, instant attack, gradual release, empty
//  input leaves the held level untouched (docs/plans/notch-panel-absorption.md live-meter fix).
//
#if os(macOS)
    import Testing
    @testable import AriCapture

    @Suite("PeakLevelMeter")
    struct PeakLevelMeterTests {
        @Test("a below-unity peak is gained x1.3")
        func gainsBelowUnityPeak() {
            var meter = PeakLevelMeter()
            let level = meter.update(with: [0.2, -0.5, 0.3])
            #expect(abs(level - 0.65) < 0.0001) // 0.5 * 1.3
        }

        @Test("a loud peak clamps at 1.0 rather than exceeding full scale")
        func clampsAtUnity() {
            var meter = PeakLevelMeter()
            let level = meter.update(with: [0.9, -1.0])
            #expect(level == 1.0)
        }

        @Test("attack is instant: a louder peak immediately raises the held level")
        func instantAttack() {
            var meter = PeakLevelMeter()
            _ = meter.update(with: [0.1])
            let level = meter.update(with: [0.5])
            #expect(abs(level - 0.65) < 0.0001) // 0.5 * 1.3, not blended with the quieter prior value
        }

        @Test("release decays the held level ~15% per window on a quieter/silent window")
        func gradualRelease() {
            var meter = PeakLevelMeter()
            let held = meter.update(with: [0.5]) // 0.65
            let decayed = meter.update(with: [Float](repeating: 0, count: 4))
            #expect(abs(decayed - held * 0.85) < 0.0001)
        }

        @Test("empty input leaves the held level unchanged (no data to attack or decay on)")
        func emptyInputIsANoOp() {
            var meter = PeakLevelMeter()
            let held = meter.update(with: [0.4])
            let unchanged = meter.update(with: [])
            #expect(unchanged == held)
        }

        @Test("silence after silence decays toward, but honestly never invents, zero")
        func decaysTowardZero() {
            var meter = PeakLevelMeter()
            _ = meter.update(with: [0.5])
            var last: Float = 1
            for _ in 0 ..< 200 {
                last = meter.update(with: [Float](repeating: 0, count: 4))
            }
            #expect(last < 0.001)
            #expect(last >= 0)
        }
    }
#endif
