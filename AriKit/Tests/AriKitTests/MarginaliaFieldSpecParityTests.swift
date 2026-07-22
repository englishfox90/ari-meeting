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

    /// The prominent (default) search field is the app-wide Apple-Music-style find — taller
    /// than the 26pt form/dropdown spec so it reads as the focal control. Locked here so a
    /// future spec tweak doesn't silently shrink every top-level search back to compact.
    @Test("prominent search field is taller than the shared 26pt field spec")
    func prominentSearchFieldIsTaller() {
        #expect(MarginaliaSearchField.prominentHeight == 38)
        #expect(MarginaliaSearchField.prominentHeight > MarginaliaFieldSpec.standard.height)
    }
}
