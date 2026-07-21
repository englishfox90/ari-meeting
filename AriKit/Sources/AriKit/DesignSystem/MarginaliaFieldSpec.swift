//
//  MarginaliaFieldSpec.swift — shared appearance spec for text-entry-shaped controls (plan
//  §5 Tier 1.1/1.2, docs/plans/arikit-component-library.md).
//
//  `MarginaliaTextField`/`MarginaliaSearchField` (1.1) and `MarginaliaMenuLabel` (1.2) share
//  one visual language — surface fill, hairline stroke (accent on focus), control radius,
//  26pt height — so the spec lives in one place and both call sites + the parity test
//  reference it, rather than duplicating four color roles across two files.
//
import CoreGraphics

public struct MarginaliaFieldSpec: Sendable, Equatable {
    public let fill: MarginaliaColorRole
    public let stroke: MarginaliaColorRole
    public let focusStroke: MarginaliaColorRole
    public let radius: MarginaliaRadius
    public let height: CGFloat

    public init(
        fill: MarginaliaColorRole,
        stroke: MarginaliaColorRole,
        focusStroke: MarginaliaColorRole,
        radius: MarginaliaRadius,
        height: CGFloat
    ) {
        self.fill = fill
        self.stroke = stroke
        self.focusStroke = focusStroke
        self.radius = radius
        self.height = height
    }

    /// The single declared appearance shared by every text-entry-shaped Marginalia control.
    public static let standard = MarginaliaFieldSpec(
        fill: .surface,
        stroke: .hairline,
        focusStroke: .accent,
        radius: .control,
        height: 26
    )
}
