//
//  MarginaliaTypography.swift — the Marginalia type ramp.
//
//  Mirrors `brand/tokens.json` → `typography.ramp`. Two families, three roles (BRAND.md
//  §5): Bricolage Grotesque for headings/display at >= 17pt only, SF Pro for body/
//  controls/metadata (and for sub-17pt headings, via Semibold), SF Mono for timecodes
//  with tabular numerals.
//
//  Only the Bricolage entries go through `Font.custom(_:size:relativeTo:)` (so headings
//  scale with Dynamic Type via `relativeTo:`); SF Pro / SF Mono resolve through
//  `Font.system(size:weight:design:)` at their exact declared point size instead of a
//  Dynamic-Type text style, since the tokens are specific pt values, not a stand-in for
//  `.body`/`.callout`/etc.
//
//  Bricolage Grotesque is NOT bundled in AriKit — it's an app-bundle font (SIL OFL,
//  self-hosted .ttf per BRAND.md §5). `Font.custom` falls back to the system font if the
//  named font isn't registered, so AriKit builds and previews cleanly without it; the app
//  target is responsible for bundling the `.ttf` and registering it in Info.plist
//  (`Fonts provided by application`) so the real face renders at runtime.
//
import SwiftUI

/// One entry in the Marginalia type ramp (`tokens.json` → `typography.ramp`).
public enum MarginaliaTextStyle: String, CaseIterable, Sendable {
    case display
    case title1
    case title2
    case headline
    case subheadline
    case body
    case callout
    case caption
    case timecode
}

/// The declared metadata for one ramp entry — face, weight, size, ink role — kept as
/// plain data (not just a `Font`) so the parity test can compare it directly against
/// `tokens.json` without trying to introspect an opaque `Font` value.
public struct MarginaliaTypeSpec: Sendable, Equatable {
    public let face: String
    public let weightValue: Int
    public let sizePt: CGFloat
    public let ink: MarginaliaColorRole
    public let isUppercase: Bool
    public let trackingEm: Double?

    var weight: Font.Weight {
        switch weightValue {
        case 400: .regular
        case 500: .medium
        case 600: .semibold
        case 700: .bold
        default: preconditionFailure("MarginaliaTypeSpec: unmapped weight \(weightValue)")
        }
    }
}

public extension MarginaliaTextStyle {
    /// The Dynamic-Type text style each ramp entry scales relative to.
    internal var relativeTextStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title1: .title
        case .title2: .title2
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .caption: .caption
        case .timecode: .caption
        }
    }

    /// The declared metadata for this ramp entry, matching `tokens.json` exactly.
    var spec: MarginaliaTypeSpec {
        switch self {
        case .display:
            MarginaliaTypeSpec(
                face: "Bricolage Grotesque", weightValue: 700, sizePt: 32, ink: .inkHeading,
                isUppercase: false, trackingEm: nil
            )
        case .title1:
            MarginaliaTypeSpec(
                face: "Bricolage Grotesque", weightValue: 700, sizePt: 24, ink: .inkHeading,
                isUppercase: false, trackingEm: nil
            )
        case .title2:
            MarginaliaTypeSpec(
                face: "Bricolage Grotesque", weightValue: 600, sizePt: 19, ink: .inkHeading,
                isUppercase: false, trackingEm: nil
            )
        case .headline:
            MarginaliaTypeSpec(
                face: "Bricolage Grotesque", weightValue: 600, sizePt: 17, ink: .inkHeading,
                isUppercase: false, trackingEm: nil
            )
        case .subheadline:
            MarginaliaTypeSpec(
                face: "SF Pro", weightValue: 600, sizePt: 15, ink: .inkBody,
                isUppercase: false, trackingEm: nil
            )
        case .body:
            MarginaliaTypeSpec(
                face: "SF Pro Text", weightValue: 400, sizePt: 14, ink: .inkBody,
                isUppercase: false, trackingEm: nil
            )
        case .callout:
            MarginaliaTypeSpec(
                face: "SF Pro Text", weightValue: 400, sizePt: 12, ink: .inkSecondary,
                isUppercase: false, trackingEm: nil
            )
        case .caption:
            MarginaliaTypeSpec(
                face: "SF Pro Text", weightValue: 600, sizePt: 11, ink: .inkSecondary,
                isUppercase: true, trackingEm: 0.07
            )
        case .timecode:
            MarginaliaTypeSpec(
                face: "SF Mono", weightValue: 500, sizePt: 12, ink: .inkBody,
                isUppercase: false, trackingEm: nil
            )
        }
    }

    /// The resolved `Font`, scaling with Dynamic Type via `relativeTo:`.
    ///
    /// ```swift
    /// Text(meeting.title).font(MarginaliaTextStyle.title1.font)
    /// ```
    ///
    /// Only Bricolage entries go through `Font.custom` (a named-font lookup); SF Pro / SF
    /// Mono are genuine system fonts and resolve through `Font.system` instead, so they
    /// don't pay for — or depend on — the custom-font-registration path at all.
    var font: Font {
        let spec = spec
        switch spec.face {
        case "Bricolage Grotesque":
            // The app bundles the brand face as two STATIC cuts — "Bricolage Grotesque SemiBold"
            // (600) and "…Bold" (700) — registered via CoreText at launch (`AppFonts`). Select
            // the concrete family by declared weight rather than driving a variable `wght` axis:
            // SwiftUI's `.weight(_:)` does NOT reliably move a registered variable font's axis, so
            // a variable file rendered at its (heavy) default instead of the intended cut. Static
            // outlines make the weight deterministic and avoid synthetic emboldening. Falls back
            // to the system font (harmless) if the app hasn't registered them.
            let family = spec.weightValue >= 700
                ? "Bricolage Grotesque Bold"
                : "Bricolage Grotesque SemiBold"
            return Font.custom(family, size: spec.sizePt, relativeTo: relativeTextStyle)
        case "SF Mono":
            return Font.system(size: spec.sizePt, weight: spec.weight, design: .monospaced)
                .monospacedDigit()
        default:
            // "SF Pro" / "SF Pro Text" — the system default design.
            return Font.system(size: spec.sizePt, weight: spec.weight, design: .default)
        }
    }

    /// Letter-spacing in points for this style at its declared size, for use with
    /// SwiftUI's `.tracking(_:)`. Only `.caption` carries a non-nil `trackingEm` today.
    var trackingPoints: CGFloat? {
        guard let trackingEm = spec.trackingEm else { return nil }
        return spec.sizePt * CGFloat(trackingEm)
    }
}
