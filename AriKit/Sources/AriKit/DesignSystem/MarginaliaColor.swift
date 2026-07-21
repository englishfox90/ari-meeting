//
//  MarginaliaColor.swift — the Marginalia color system ("two inks on paper").
//
//  Mirrors `brand/tokens.json` → `modes.light` / `modes.dark`. Source of truth is
//  brand/BRAND.md §4; this file must never invent a value not present there — the
//  token-parity suite (AriKitTests/MarginaliaTokenParityTests) enforces that.
//
//  DesignSystem lives in AriKit (not an app target) because both the macOS `Ari` app and
//  the iOS `Ari Lite` app consume it (plan "Target architecture").
//
import SwiftUI

/// Every color role in the Marginalia system. One case per `tokens.json` key under
/// `modes.light` / `modes.dark`.
public enum MarginaliaColorRole: String, CaseIterable, Sendable {
    case canvas
    case elevated
    case surface
    case inkBody
    case inkHeading
    case inkSecondary
    case hairline
    case accent
    case accentHover
    case accentPressed
    case selectionWash
    case recordingRed
    case recordingRedPressed
    case success
    case error
}

/// The raw token strings for one color mode, exactly as they appear in `tokens.json`.
/// Kept separate from the resolved `Color` values so the parity test can compare
/// strings/components without round-tripping through `SwiftUI.Color` (which does not
/// expose its components losslessly across platforms).
struct MarginaliaColorTokens: Sendable, Equatable {
    var canvas: String
    var elevated: String
    var surface: String
    var inkBody: String
    var inkHeading: String
    var inkSecondary: String
    var hairline: String
    var accent: String
    var accentHover: String
    var accentPressed: String
    /// CSS `rgba(r, g, b, a)` — the one non-hex token in the palette (selectionWash).
    var selectionWashRGBA: String
    var recordingRed: String
    var recordingRedPressed: String
    var success: String
    var error: String

    // swiftlint:disable:next cyclomatic_complexity
    func hex(for role: MarginaliaColorRole) -> String? {
        switch role {
        case .canvas: canvas
        case .elevated: elevated
        case .surface: surface
        case .inkBody: inkBody
        case .inkHeading: inkHeading
        case .inkSecondary: inkSecondary
        case .hairline: hairline
        case .accent: accent
        case .accentHover: accentHover
        case .accentPressed: accentPressed
        case .recordingRed: recordingRed
        case .recordingRedPressed: recordingRedPressed
        case .success: success
        case .error: error
        case .selectionWash: nil
        }
    }
}

enum MarginaliaColorTokenSource {
    /// `brand/tokens.json` → `modes.light`.
    static let light = MarginaliaColorTokens(
        canvas: "#FAF8F5",
        elevated: "#F1EDE6",
        surface: "#FFFFFF",
        inkBody: "#2B2620",
        inkHeading: "#152C66",
        inkSecondary: "#6F6759",
        hairline: "#E6E1D8",
        accent: "#1B3A8C",
        accentHover: "#16317A",
        accentPressed: "#122763",
        selectionWashRGBA: "rgba(27, 58, 140, 0.11)",
        recordingRed: "#C6362C",
        recordingRedPressed: "#A62B22",
        success: "#42794F",
        error: "#9A3327"
    )

    /// `brand/tokens.json` → `modes.dark`.
    static let dark = MarginaliaColorTokens(
        canvas: "#211E1B",
        elevated: "#2B2723",
        surface: "#2D2925",
        inkBody: "#EDE8E1",
        inkHeading: "#E8EAF2",
        inkSecondary: "#A89F92",
        hairline: "#3E3933",
        accent: "#7E9BE8",
        accentHover: "#92ABEC",
        accentPressed: "#6B89DE",
        selectionWashRGBA: "rgba(126, 155, 232, 0.16)",
        recordingRed: "#FF6B5E",
        recordingRedPressed: "#E85548",
        success: "#8CC2A0",
        error: "#EB9A8E"
    )
}

/// 0...1 RGBA components. A named struct (not a 3/4-member tuple) so both this file and
/// the token-parity test can pass components around without tripping SwiftLint's
/// `large_tuple` rule.
struct MarginaliaRGBAComponents: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
}

/// Parses the two token formats used in `tokens.json`: `#RRGGBB` hex and CSS
/// `rgba(r, g, b, a)` (0–255 channels, 0–1 alpha). Internal (not a `Color` extension) so
/// it stays a Marginalia-only concern rather than polluting every `Color` call site.
enum MarginaliaColorParsing {
    /// Parses `#RRGGBB` into 0...1 RGB components. Traps on malformed input — these are
    /// compiled-in brand constants, not user data.
    static func hexComponents(_ hex: String) -> MarginaliaRGBAComponents {
        var chars = hex
        if chars.hasPrefix("#") {
            chars.removeFirst()
        }
        guard chars.count == 6, let value = UInt32(chars, radix: 16) else {
            preconditionFailure("MarginaliaColorParsing: malformed hex token '\(hex)'")
        }
        return MarginaliaRGBAComponents(
            red: Double((value & 0xFF0000) >> 16) / 255.0,
            green: Double((value & 0x00FF00) >> 8) / 255.0,
            blue: Double(value & 0x0000FF) / 255.0
        )
    }

    /// Parses a CSS `rgba(r, g, b, a)` string into 0...1 components.
    static func rgbaComponents(_ rgba: String) -> MarginaliaRGBAComponents {
        let digits = rgba
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard digits.count == 4,
              let red = Double(digits[0]),
              let green = Double(digits[1]),
              let blue = Double(digits[2]),
              let alpha = Double(digits[3])
        else {
            preconditionFailure("MarginaliaColorParsing: malformed rgba token '\(rgba)'")
        }
        return MarginaliaRGBAComponents(red: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: alpha)
    }

    static func color(hex: String) -> Color {
        let components = hexComponents(hex)
        return Color(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: 1)
    }

    static func color(rgba: String) -> Color {
        let components = rgbaComponents(rgba)
        return Color(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: components.alpha
        )
    }
}

/// A fully-resolved set of `Color` values for one color scheme (light or dark).
public struct MarginaliaPalette: Sendable {
    public let canvas: Color
    public let elevated: Color
    public let surface: Color
    public let inkBody: Color
    public let inkHeading: Color
    public let inkSecondary: Color
    public let hairline: Color
    public let accent: Color
    public let accentHover: Color
    public let accentPressed: Color
    public let selectionWash: Color
    public let recordingRed: Color
    public let recordingRedPressed: Color
    public let success: Color
    public let error: Color

    init(tokens: MarginaliaColorTokens) {
        canvas = MarginaliaColorParsing.color(hex: tokens.canvas)
        elevated = MarginaliaColorParsing.color(hex: tokens.elevated)
        surface = MarginaliaColorParsing.color(hex: tokens.surface)
        inkBody = MarginaliaColorParsing.color(hex: tokens.inkBody)
        inkHeading = MarginaliaColorParsing.color(hex: tokens.inkHeading)
        inkSecondary = MarginaliaColorParsing.color(hex: tokens.inkSecondary)
        hairline = MarginaliaColorParsing.color(hex: tokens.hairline)
        accent = MarginaliaColorParsing.color(hex: tokens.accent)
        accentHover = MarginaliaColorParsing.color(hex: tokens.accentHover)
        accentPressed = MarginaliaColorParsing.color(hex: tokens.accentPressed)
        selectionWash = MarginaliaColorParsing.color(rgba: tokens.selectionWashRGBA)
        recordingRed = MarginaliaColorParsing.color(hex: tokens.recordingRed)
        recordingRedPressed = MarginaliaColorParsing.color(hex: tokens.recordingRedPressed)
        success = MarginaliaColorParsing.color(hex: tokens.success)
        error = MarginaliaColorParsing.color(hex: tokens.error)
    }

    /// Resolves a role to its `Color` in this palette. Prefer `Color.marginalia(_:in:)`
    /// from SwiftUI call sites; this subscript is what that helper (and the parity test)
    /// use underneath.
    public subscript(_ role: MarginaliaColorRole) -> Color {
        switch role {
        case .canvas: canvas
        case .elevated: elevated
        case .surface: surface
        case .inkBody: inkBody
        case .inkHeading: inkHeading
        case .inkSecondary: inkSecondary
        case .hairline: hairline
        case .accent: accent
        case .accentHover: accentHover
        case .accentPressed: accentPressed
        case .selectionWash: selectionWash
        case .recordingRed: recordingRed
        case .recordingRedPressed: recordingRedPressed
        case .success: success
        case .error: error
        }
    }
}

/// The two Marginalia palettes and the scheme-aware resolver.
///
/// ```swift
/// // In a SwiftUI view:
/// @Environment(\.colorScheme) private var colorScheme
/// var body: some View {
///     Text("Recording").foregroundStyle(Color.marginalia(.accent, in: colorScheme))
/// }
/// ```
public enum MarginaliaColors {
    /// `brand/tokens.json` → `modes.light`, resolved to `Color`.
    public static let light = MarginaliaPalette(tokens: MarginaliaColorTokenSource.light)
    /// `brand/tokens.json` → `modes.dark`, resolved to `Color`.
    public static let dark = MarginaliaPalette(tokens: MarginaliaColorTokenSource.dark)

    /// Resolves a role against the given `ColorScheme` (`.light`/`.dark` only — Marginalia
    /// ships exactly two modes).
    public static func resolve(_ role: MarginaliaColorRole, for scheme: ColorScheme) -> Color {
        (scheme == .dark ? dark : light)[role]
    }
}

public extension Color {
    /// Ergonomic call-site sugar: `Color.marginalia(.accent, in: colorScheme)`.
    static func marginalia(_ role: MarginaliaColorRole, in scheme: ColorScheme) -> Color {
        MarginaliaColors.resolve(role, for: scheme)
    }
}
