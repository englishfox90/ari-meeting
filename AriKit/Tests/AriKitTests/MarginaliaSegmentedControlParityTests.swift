//
//  MarginaliaSegmentedControlParityTests.swift — asserts the segment selection -> button
//  role mapping declared in docs/plans/arikit-component-library.md §5 Tier 1.3.
//
import Testing
@testable import AriKit

@Suite("MarginaliaSegmentedControl parity (selection -> button role)")
struct MarginaliaSegmentedControlParityTests {

    @Test("selected segment resolves to the secondary role (tonal, not solid accent)")
    func selectedRole() {
        #expect(MarginaliaSegmentedControl<String>.role(selected: true) == .secondary)
    }

    @Test("unselected segment resolves to the quiet role")
    func unselectedRole() {
        #expect(MarginaliaSegmentedControl<String>.role(selected: false) == .quiet)
    }
}
