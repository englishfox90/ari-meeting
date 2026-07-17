//
//  MarginaliaSpacing.swift — the Marginalia spacing + radius scales.
//
//  Mirrors `brand/tokens.json` → `spacing` ([4, 8, 12, 16, 24, 32, 40, 48]) and `radii`
//  (control 6 / card 10 / dialog 14). Named steps rather than a raw index, so call sites
//  read as intent ("md" gutter) rather than a magic array position.
//
import CoreGraphics

/// The eight-step spacing scale from `tokens.json` → `spacing`.
///
/// ```swift
/// VStack(spacing: MarginaliaSpacing.md.value) { … }
/// ```
/// LOCKSTEP WARNING: `value` resolves a case to `tokenValues` by `rawValue` (declaration
/// order = array index). Never reorder these cases or insert a new one in the middle
/// without updating `tokenValues` (and `tokens.json`) to match — doing so silently
/// reassigns every step after the change to the wrong pt value. Append-only is safe.
public enum MarginaliaSpacing: Int, CaseIterable, Sendable {
    case xs // 4
    case sm // 8
    case md // 12
    case lg // 16
    case xl // 24
    case xxl // 32
    case xxxl // 40
    case huge // 48

    /// The raw `tokens.json` `spacing` array, in scale order. Kept alongside the enum so
    /// the parity test can walk both in lockstep. See the LOCKSTEP WARNING above.
    static let tokenValues: [CGFloat] = [4, 8, 12, 16, 24, 32, 40, 48]

    public var value: CGFloat {
        Self.tokenValues[rawValue]
    }
}

/// The three corner radii from `tokens.json` → `radii`.
public enum MarginaliaRadius: Sendable {
    case control
    case card
    case dialog

    public var value: CGFloat {
        switch self {
        case .control: 6
        case .card: 10
        case .dialog: 14
        }
    }
}
