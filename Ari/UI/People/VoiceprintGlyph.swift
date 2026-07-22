//
//  VoiceprintGlyph.swift — a person/speaker's "voiceprint identicon": a compact ring whose
//  outline is deterministically shaped by a REAL voiceprint signature (docs/plans/
//  people-view-parity.md §2.5; ← `frontend/src/components/MeetingDetails/VoiceprintGlyph.tsx` +
//  `frontend/src/lib/voiceprint-glyph.ts`).
//
//  Same voice → same ring; cosine-similar voices land on visually similar rings because the
//  signature is a direct down-sample of the centroid (never a hash). Honours No-Fake-State: a
//  `nil` signature (or one too short to derive a shape from) renders a neutral placeholder dot,
//  never an invented ring.
//
//  Reusable: the People list uses this as a small (~28pt) row avatar; the person-detail header
//  (Slice 4) reuses it larger, with `isActive` flipping on only while a clip is playing (the
//  Signal rule — amber is reserved for that one signal, never a resting decoration).
//
import AriKit
import AriViewModels
import SwiftUI

struct VoiceprintGlyph: View {
    /// The person/speaker's voiceprint signature (bucketed, normalized `[0, 1]` values), or `nil`
    /// when no real voiceprint has been enrolled yet — renders a neutral placeholder, never a
    /// fabricated ring.
    let signature: [Float]?
    /// Rendered edge length in points.
    let size: CGFloat
    /// Amber signal — true only while this voice's clip is actively playing. Off by default; the
    /// glyph is otherwise a warm-neutral, voice-derived data color.
    var isActive: Bool = false

    @Environment(\.colorScheme) private var scheme

    private var ring: [Double]? {
        signature.flatMap(VoiceprintRing.ringRadii)
    }

    private var voiceColor: VoiceprintColor? {
        guard !isActive, let signature else { return nil }
        return VoiceprintRing.color(signature, dark: scheme == .dark)
    }

    var body: some View {
        Group {
            if let ring {
                ringShape(ring)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Real ring

    private func ringShape(_ radii: [Double]) -> some View {
        let path = Self.closedCatmullRomPath(radii: radii, edge: size)
        let strokeWidth: CGFloat = size <= 20 ? 1.25 : 1.5
        return ZStack {
            if let voiceColor {
                let gradient = LinearGradient(
                    colors: [Self.color(voiceColor.hueFrom, voiceColor), Self.color(voiceColor.hueTo, voiceColor)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                path.fill(gradient, style: FillStyle(eoFill: false)).opacity(0.1)
                path.stroke(gradient, lineWidth: strokeWidth)
            } else {
                // `isActive` (Signal accent) or a color-less fallback: the amber-only-while-
                // playing accent, or a plain ink tone when no derived color applies.
                let tint = isActive
                    ? Color.marginalia(.accent, in: scheme)
                    : Color.marginalia(.inkSecondary, in: scheme)
                path.fill(tint).opacity(0.1)
                path.stroke(tint, lineWidth: strokeWidth)
            }
        }
    }

    private static func color(_ hueDegrees: Double, _ voiceColor: VoiceprintColor) -> Color {
        Color(
            hue: hueDegrees / 360,
            saturation: voiceColor.saturation / 100,
            brightness: voiceColor.lightness / 100
        )
    }

    /// Builds a closed ring `Path` from per-bucket radii via a centripetal-style Catmull-Rom
    /// spline converted to cubic Béziers (← `buildVoiceprintRing` in the TS port) — a calm,
    /// organic outline rather than a faceted polygon.
    private static func closedCatmullRomPath(radii: [Double], edge: CGFloat) -> Path {
        let n = radii.count
        let half = Double(edge) / 2
        func point(_ i: Int) -> CGPoint {
            let index = ((i % n) + n) % n
            let radius = radii[index]
            let angle = (Double(index) / Double(n)) * 2 * .pi - .pi / 2
            return CGPoint(x: half + radius * cos(angle), y: half + radius * sin(angle))
        }

        var path = Path()
        path.move(to: point(0))
        for i in 0 ..< n {
            let p0 = point(i - 1)
            let p1 = point(i)
            let p2 = point(i + 1)
            let p3 = point(i + 2)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Honest placeholder (No-Fake-State)

    private var placeholder: some View {
        let dotSize = max(3, size * 0.16)
        return Circle()
            .fill(Color.marginalia(.inkSecondary, in: scheme).opacity(0.4))
            .frame(width: dotSize, height: dotSize)
    }
}
