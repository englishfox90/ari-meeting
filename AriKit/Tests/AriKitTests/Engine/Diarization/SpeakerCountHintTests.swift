//
//  SpeakerCountHintTests.swift — ← Rust `tuning.rs` clamp semantics (test 62,
//  `clamps_fixed_count_to_sane_range`), ported to `SpeakerCountHint` (plan §5, D3).
//
import Testing
@testable import AriKit

@Suite("SpeakerCountHint")
struct SpeakerCountHintTests {
    // ---- exact: clamped 1...20 ----

    @Test
    func clampedExactWithinRangeIsUnchanged() {
        #expect(SpeakerCountHint.clampedExact(5) == .exact(5))
    }

    @Test
    func clampedExactBelowRangeFloorsAtOne() {
        #expect(SpeakerCountHint.clampedExact(0) == .exact(1))
        #expect(SpeakerCountHint.clampedExact(-4) == .exact(1))
    }

    @Test
    func clampedExactAboveRangeCapsAtTwenty() {
        #expect(SpeakerCountHint.clampedExact(999) == .exact(20))
    }

    @Test
    func clampedExactAtBoundariesIsUnchanged() {
        #expect(SpeakerCountHint.clampedExact(1) == .exact(1))
        #expect(SpeakerCountHint.clampedExact(20) == .exact(20))
    }

    // ---- upperBound: clamped 2...12 ----

    @Test
    func clampedUpperBoundWithinRangeIsUnchanged() {
        #expect(SpeakerCountHint.clampedUpperBound(6) == .upperBound(6))
    }

    @Test
    func clampedUpperBoundBelowRangeFloorsAtTwo() {
        #expect(SpeakerCountHint.clampedUpperBound(0) == .upperBound(2))
        #expect(SpeakerCountHint.clampedUpperBound(1) == .upperBound(2))
    }

    @Test
    func clampedUpperBoundAboveRangeCapsAtTwelve() {
        #expect(SpeakerCountHint.clampedUpperBound(999) == .upperBound(12))
    }

    @Test
    func clampedUpperBoundAtBoundariesIsUnchanged() {
        #expect(SpeakerCountHint.clampedUpperBound(2) == .upperBound(2))
        #expect(SpeakerCountHint.clampedUpperBound(12) == .upperBound(12))
    }

    // ---- .automatic never reaches production (I4) ----

    @Test
    func automaticIsDistinctFromExactAndUpperBound() {
        #expect(SpeakerCountHint.automatic != .exact(1))
        #expect(SpeakerCountHint.automatic != .upperBound(2))
    }
}
