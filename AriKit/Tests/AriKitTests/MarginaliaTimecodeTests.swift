//
//  MarginaliaTimecodeTests.swift — parity for MarginaliaTimecode.mmss (plan §6-1).
//
import Testing
@testable import AriKit

@Suite("MarginaliaTimecode.mmss formatting")
struct MarginaliaTimecodeTests {

    @Test("0 seconds formats as 00:00")
    func zeroSeconds() {
        #expect(MarginaliaTimecode.mmss(0) == "00:00")
    }

    @Test("61 seconds formats as 01:01")
    func sixtyOneSeconds() {
        #expect(MarginaliaTimecode.mmss(61) == "01:01")
    }

    @Test("599 seconds formats as 09:59")
    func fiveHundredNinetyNineSeconds() {
        #expect(MarginaliaTimecode.mmss(599) == "09:59")
    }

    @Test("89.6 seconds rounds up to 01:30")
    func fractionalSecondsRound() {
        #expect(MarginaliaTimecode.mmss(89.6) == "01:30")
    }
}
