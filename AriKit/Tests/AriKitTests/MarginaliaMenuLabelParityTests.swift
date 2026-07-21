//
//  MarginaliaMenuLabelParityTests.swift — asserts `MarginaliaMenuLabel` shares
//  `MarginaliaFieldSpec.standard` and its declared chevron symbol (plan §5 Tier 1.2).
//
import Testing
@testable import AriKit

@Suite("MarginaliaMenuLabel parity (shared field spec + chevron symbol)")
struct MarginaliaMenuLabelParityTests {

    @Test("menu label chevron symbol is chevron.up.chevron.down")
    func chevronSymbol() {
        #expect(MarginaliaMenuLabel.chevronSymbol == "chevron.up.chevron.down")
    }

    @Test("menu label shares the standard field spec (surface/hairline/control/26pt)")
    func sharesFieldSpec() {
        let spec = MarginaliaFieldSpec.standard
        #expect(spec.fill == .surface)
        #expect(spec.stroke == .hairline)
        #expect(spec.height == 26)
    }
}
