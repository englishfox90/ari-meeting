//
//  MarginaliaBadgeStyleParityTests.swift — asserts the badge style/role mapping declared in
//  docs/plans/arikit-component-library.md §5 Tier 1.4, mirroring
//  MarginaliaButtonStyleParityTests's style of testing plain-data specs.
//
import Testing
@testable import AriKit

@Suite("Marginalia badge style parity (style -> color-role / required-symbol)")
struct MarginaliaBadgeStyleParityTests {

    @Test("neutral style: elevated fill, inkSecondary label, hairline stroke, no required symbol")
    func neutralSpec() {
        let spec = MarginaliaBadgeStyle.neutral.spec
        #expect(spec.fill == .elevated)
        #expect(spec.label == .inkSecondary)
        #expect(spec.stroke == .hairline)
        #expect(spec.requiredSymbol == nil)
    }

    @Test("accent style: selectionWash fill, accent label, no stroke, no required symbol")
    func accentSpec() {
        let spec = MarginaliaBadgeStyle.accent.spec
        #expect(spec.fill == .selectionWash)
        #expect(spec.label == .accent)
        #expect(spec.stroke == nil)
        #expect(spec.requiredSymbol == nil)
    }

    @Test("success style: solid success fill, canvas label, checkmark.seal required symbol")
    func successSpec() {
        let spec = MarginaliaBadgeStyle.success.spec
        #expect(spec.fill == .success)
        #expect(spec.label == .canvas)
        #expect(spec.stroke == nil)
        #expect(spec.requiredSymbol == "checkmark.seal")
    }

    @Test("recording style: solid recordingRed fill, canvas label, record.circle required symbol")
    func recordingSpec() {
        let spec = MarginaliaBadgeStyle.recording.spec
        #expect(spec.fill == .recordingRed)
        #expect(spec.label == .canvas)
        #expect(spec.stroke == nil)
        #expect(spec.requiredSymbol == "record.circle")
    }
}
