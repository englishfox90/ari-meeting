//
//  SegmentSourceTests.swift — the diarization-plan §2.8 `SegmentSource` extension (plan §5, D3).
//
import Foundation
import Testing
@testable import AriKit

@Suite("SegmentSource")
struct SegmentSourceTests {
    @Test
    func systemAndMicrophoneAreKnownCases() {
        #expect(SegmentSource(rawValue: "system") == .system)
        #expect(SegmentSource(rawValue: "microphone") == .microphone)
        #expect(SegmentSource.system.rawValue == "system")
        #expect(SegmentSource.microphone.rawValue == "microphone")
    }

    @Test
    func ownerIsNotAKnownCase() {
        // (parity-L1) Rust segment sources are only "system"/"microphone" — there is no ".owner"
        // segment source (that's a cluster_key/enrollment-state concept). An "owner" raw is an
        // unrecognized value here.
        #expect(SegmentSource(rawValue: "owner") == nil)
    }

    @Test
    func unrecognizedRawDecodesToUnknown() {
        #expect(SegmentSource(rawValue: "futureValue") == nil)
        #expect(SegmentSource.unknownCase("futureValue") == .unknown("futureValue"))
    }

    /// swift-L2: a previously-imported `.unknown("system")`/`.unknown("microphone")` row (the
    /// only decode available before this enum learned those raws) now decodes to the known case
    /// on next read — no re-import or migration needed, since the underlying stored String is
    /// unchanged.
    @Test
    func legacyImportedRawSourcesUpgradeToKnownCases() {
        let legacySystem = SegmentSource.unknown("system")
        let legacyMicrophone = SegmentSource.unknown("microphone")

        #expect(SegmentSource(rawValue: legacySystem.rawValue) == .system)
        #expect(SegmentSource(rawValue: legacyMicrophone.rawValue) == .microphone)
    }
}
