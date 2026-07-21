//
//  MarginaliaBannerStyleParityTests.swift — asserts the banner kind -> symbol/tint mapping
//  declared in docs/plans/arikit-component-library.md §5 Tier 1.6.
//
import Testing
@testable import AriKit

@Suite("Marginalia banner style parity (kind -> symbol/tint)")
struct MarginaliaBannerStyleParityTests {

    @Test("info kind: info.circle symbol, inkSecondary tint")
    func infoSpec() {
        let spec = MarginaliaBannerKind.info.spec
        #expect(spec.symbol == "info.circle")
        #expect(spec.tint == .inkSecondary)
    }

    @Test("success kind: checkmark.seal symbol, success tint")
    func successSpec() {
        let spec = MarginaliaBannerKind.success.spec
        #expect(spec.symbol == "checkmark.seal")
        #expect(spec.tint == .success)
    }

    @Test("error kind: exclamationmark.triangle symbol, recordingRed tint")
    func errorSpec() {
        let spec = MarginaliaBannerKind.error.spec
        #expect(spec.symbol == "exclamationmark.triangle")
        #expect(spec.tint == .recordingRed)
    }
}
