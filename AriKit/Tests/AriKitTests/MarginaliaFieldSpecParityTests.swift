//
//  MarginaliaFieldSpecParityTests.swift — asserts the shared field appearance declared in
//  docs/plans/arikit-component-library.md §5 Tier 1.1/1.2.
//
import Testing
@testable import AriKit

@Suite("MarginaliaFieldSpec parity (shared by text/search field and menu label)")
struct MarginaliaFieldSpecParityTests {

    @Test("standard spec: surface fill, hairline stroke, accent focus stroke, control radius, 26pt height")
    func standardSpec() {
        let spec = MarginaliaFieldSpec.standard
        #expect(spec.fill == .surface)
        #expect(spec.stroke == .hairline)
        #expect(spec.focusStroke == .accent)
        #expect(spec.radius.value == MarginaliaRadius.control.value)
        #expect(spec.height == 26)
    }
}
