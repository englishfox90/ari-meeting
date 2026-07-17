//
//  MarginaliaMotion.swift — the Marginalia motion tokens.
//
//  Mirrors `brand/tokens.json` → `motion`. Product UI is state-driven only (BRAND.md §8):
//  animation communicates recording, live transcription, processing, and transitions — it
//  never decorates. Callers are responsible for honoring Reduce Motion (pulses become
//  static, transitions become fades); this layer only supplies the timing primitives.
//
import SwiftUI

/// The three duration steps from `tokens.json` → `motion.durationsMs`.
public enum MarginaliaDuration: Sendable {
    case instant // 120ms — press feedback, micro-state.
    case fast // 180ms — hover, selection, compact disclosure.
    case standard // 260ms — sidebar, dialog, panel state changes.

    public var milliseconds: Double {
        switch self {
        case .instant: 120
        case .fast: 180
        case .standard: 260
        }
    }

    public var seconds: Double {
        milliseconds / 1000
    }
}

/// The four cubic-bezier control points shared by every Marginalia animation
/// (`tokens.json` → `motion.easing`: `cubic-bezier(0.23, 1, 0.32, 1)`). A named struct
/// (not a 4-member tuple) so it stays SwiftLint-clean.
public struct MarginaliaEasingCurve: Sendable, Equatable {
    public let c1x: Double
    public let c1y: Double
    public let c2x: Double
    public let c2y: Double
}

/// Motion helpers built from the single Marginalia easing curve.
public enum MarginaliaMotion {
    public static let easing = MarginaliaEasingCurve(c1x: 0.23, c1y: 1, c2x: 0.32, c2y: 1)

    /// The SwiftUI `Animation` for a given duration step, using the Marginalia easing
    /// curve. Product code must gate its use on real state changes (BRAND.md §8) — this
    /// helper does not itself check `accessibilityReduceMotion`; call sites should.
    public static func animation(_ duration: MarginaliaDuration) -> Animation {
        .timingCurve(easing.c1x, easing.c1y, easing.c2x, easing.c2y, duration: duration.seconds)
    }
}
