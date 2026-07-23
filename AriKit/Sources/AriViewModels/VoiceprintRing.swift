//
//  VoiceprintRing.swift — voiceprint ring geometry + color (pure, UI-free)
//  (← `frontend/src/lib/voiceprint-glyph.ts` `buildVoiceprintRing`/`voiceprintColors`).
//
//  AriViewModels never imports SwiftUI/CoreGraphics — this returns plain numbers;
//  the SwiftUI View layer maps them to points/Path. Deterministic by
//  construction: the same signature always yields the same radii/color.
//
import Foundation

/// A deterministic, voice-derived stroke color: two hue stops for a subtle
/// gradient along the ring. Hue is expressed in **degrees, `[0, 360)`** (matching
/// the TS port's `hueFrom`/`hueTo` fields) — the View layer converts to whatever
/// unit its color API expects (e.g. SwiftUI `Color(hue:saturation:brightness:)`
/// wants `[0, 1]`, so divide by 360 there).
public struct VoiceprintColor: Sendable, Equatable {
    /// Primary hue in degrees `[0, 360)`.
    public let hueFrom: Double
    /// Secondary hue in degrees `[0, 360)`.
    public let hueTo: Double
    /// Shared saturation percentage (kept in the calm data band, 46–64).
    public let saturation: Double
    /// Shared lightness percentage (theme-dependent).
    public let lightness: Double

    public init(hueFrom: Double, hueTo: Double, saturation: Double, lightness: Double) {
        self.hueFrom = hueFrom
        self.hueTo = hueTo
        self.saturation = saturation
        self.lightness = lightness
    }
}

public enum VoiceprintRing {
    /// Inner/outer radius as a fraction of half the glyph's size — the ring
    /// breathes between these ratios (`minRadiusRatio`/`maxRadiusRatio` in the
    /// TS port).
    public static let minRadiusRatio = 0.46
    public static let maxRadiusRatio = 0.94

    /// Per-bucket radii as a **fraction of half the glyph size** in
    /// `[minRadiusRatio, maxRadiusRatio]` — the View layer multiplies by `half`
    /// (`size / 2`) to get absolute points. Input values are expected in `[0, 1]`
    /// (clamped if not). Returns `nil` when there is nothing honest to draw
    /// (fewer than 3 values) so the caller falls back to a neutral placeholder
    /// rather than inventing a shape.
    public static func ringRadii(_ values: [Float]) -> [Double]? {
        guard values.count >= 3 else { return nil }
        let span = maxRadiusRatio - minRadiusRatio
        return values.map { raw in
            let v = Double(raw).clamped(to: 0.0 ... 1.0)
            return minRadiusRatio + v * span
        }
    }

    /// Derive a deterministic, voice-based color from a signature.
    ///
    /// The bucket values are treated as weights on evenly-spaced angles around a
    /// circle (bucket `i` → angle `2π·i/n`). The circular mean of that weighted
    /// vector gives the primary hue; a second, independent projection over the
    /// odd-indexed buckets only gives the secondary hue (the two-stop gradient).
    /// Saturation comes from the primary projection's concentration (vector
    /// magnitude), clamped into a calm 46–64% band. Lightness is theme-dependent
    /// (lighter on dark, deeper on cream). Returns `nil` when there are fewer
    /// than 3 values (matching `ringRadii`).
    public static func color(_ values: [Float], dark: Bool) -> VoiceprintColor? {
        let n = values.count
        guard n >= 3 else { return nil }
        let v = values.map { Double($0).clamped(to: 0.0 ... 1.0) }

        func project(keep: (Int) -> Bool) -> (hue: Double, mag: Double) {
            var sx = 0.0
            var sy = 0.0
            var sw = 0.0
            for i in 0 ..< n where keep(i) {
                let angle = (Double(i) / Double(n)) * 2 * .pi
                sx += v[i] * cos(angle)
                sy += v[i] * sin(angle)
                sw += v[i]
            }
            let hue = (atan2(sy, sx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            let mag = sw > 0 ? min(1, (sx * sx + sy * sy).squareRoot() / sw) : 0
            return (hue, mag)
        }

        let primary = project { _ in true }
        let secondary = project { $0 % 2 == 1 }

        let saturation = (46 + primary.mag * 18).rounded()
        let lightness: Double = dark ? 66 : 40

        let hueFrom = primary.hue.rounded().truncatingRemainder(dividingBy: 360)
        let hueTo = secondary.hue.rounded().truncatingRemainder(dividingBy: 360)

        return VoiceprintColor(hueFrom: hueFrom, hueTo: hueTo, saturation: saturation, lightness: lightness)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
