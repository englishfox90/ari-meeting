//
//  MarginaliaButtonStyleParityTests.swift — asserts the button role/size mapping declared
//  in docs/plans/arikit-native-read-ui.md §4, mirroring MarginaliaTokenParityTests's style
//  of testing plain-data specs rather than introspecting an opaque `ButtonStyle`.
//
import Testing
@testable import AriKit

@Suite("Marginalia button style parity (role -> color-role, size -> control height)")
struct MarginaliaButtonStyleParityTests {

    @Test("primary role: solid accent fill, canvas (paper) label, no stroke, accentPressed pressed")
    func primarySpec() {
        let spec = MarginaliaButtonRole.primary.spec
        #expect(spec.fill == .accent)
        // `.canvas`, not `.surface`: stays high-contrast on the accent fill in both schemes
        // (see the rationale comment in MarginaliaButtonStyle).
        #expect(spec.label == .canvas)
        #expect(spec.stroke == nil)
        #expect(spec.pressed == .accentPressed)
    }

    @Test("secondary role: elevated tonal fill, inkBody label, hairline stroke, selectionWash pressed")
    func secondarySpec() {
        let spec = MarginaliaButtonRole.secondary.spec
        #expect(spec.fill == .elevated)
        #expect(spec.label == .inkBody)
        #expect(spec.stroke == .hairline)
        #expect(spec.pressed == .selectionWash)
    }

    @Test("quiet role: no fill, accent label, no stroke, selectionWash pressed")
    func quietSpec() {
        let spec = MarginaliaButtonRole.quiet.spec
        #expect(spec.fill == nil)
        #expect(spec.label == .accent)
        #expect(spec.stroke == nil)
        #expect(spec.pressed == .selectionWash)
    }

    @Test("recording role: solid recordingRed fill, canvas (paper) label, no stroke")
    func recordingSpec() {
        let spec = MarginaliaButtonRole.recording.spec
        #expect(spec.fill == .recordingRed)
        #expect(spec.label == .canvas)
        #expect(spec.stroke == nil)
        #expect(spec.pressed == .recordingRed)
    }

    @Test("regular size resolves to 26pt; large size resolves to 32pt")
    func sizeControlHeights() {
        #expect(MarginaliaButtonSize.regular.controlHeight == 26)
        #expect(MarginaliaButtonSize.large.controlHeight == 32)
    }
}
