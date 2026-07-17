//
//  MarginaliaTokenParityTests.swift — the Swift mirror of frontend's visual-system.test.mjs.
//
//  Loads brand/tokens.json at test time and asserts the DesignSystem's Swift constants
//  match it exactly, so the two can never silently drift. Locates tokens.json by walking
//  up from #filePath rather than hardcoding an absolute path, since the repo can be
//  checked out anywhere.
//
import Foundation
import SwiftUI
import Testing
@testable import AriKit

// MARK: - tokens.json loading

private enum TokensJSONLocator {
    /// Walks up from this test file's location until it finds `brand/tokens.json`.
    static func locate() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while true {
            let candidate = directory.appendingPathComponent("brand/tokens.json")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            precondition(
                parent.path != directory.path,
                "MarginaliaTokenParityTests: could not locate brand/tokens.json by walking up from \(#filePath)"
            )
            directory = parent
        }
    }

    static func load() -> TokensJSON {
        let url = locate()
        let data = try! Data(contentsOf: url) // swiftlint:disable:this force_try
        return try! JSONDecoder().decode(TokensJSON.self, from: data) // swiftlint:disable:this force_try
    }
}

// MARK: - tokens.json shape (only the fields this suite checks)

//
// Kept as top-level (not nested) types — one level of nesting only — to stay
// SwiftLint-clean; the "TokensJSON" prefix keeps them from colliding with the
// DesignSystem's own types.

private struct TokensJSONPalette: Decodable {
    let canvas: String
    let elevated: String
    let surface: String
    let inkBody: String
    let inkHeading: String
    let inkSecondary: String
    let hairline: String
    let accent: String
    let accentHover: String
    let accentPressed: String
    let selectionWash: String
    let recordingRed: String
    let success: String
}

private struct TokensJSONModes: Decodable {
    let light: TokensJSONPalette
    let dark: TokensJSONPalette
}

private struct TokensJSONRampEntry: Decodable {
    let style: String
    let face: String
    let weight: Int
    let sizePt: Int
    let ink: String
    let trackingEm: Double?
    let transform: String?
}

private struct TokensJSONTypography: Decodable {
    let ramp: [TokensJSONRampEntry]
}

private struct TokensJSONRadii: Decodable {
    let control: Int
    let card: Int
    let dialog: Int
}

private struct TokensJSONRules: Decodable {
    let accentMaxCoverage: Double
    let accentAllowedOn: [String]
    /// A descriptive rule (prose), not a boolean — see the note on `rulesMatch()` below.
    let accentSolidFill: String
    let headingInkInteractive: Bool
    let noFakeState: Bool
    let recordingAlwaysConsented: Bool
    let warmNeutralsOnly: Bool
    let bricolageMinSizePt: Int
    let markMinFullSizePx: Int
}

private struct TokensJSON: Decodable {
    let modes: TokensJSONModes
    let spacing: [Int]
    let radii: TokensJSONRadii
    let typography: TokensJSONTypography
    let rules: TokensJSONRules
}

// MARK: - shared parsing (a deliberately independent reimplementation of

// MarginaliaColorParsing's spec — reuses `MarginaliaRGBAComponents` as the shared value
// type, but NOT the parser itself, so this suite fails if the DesignSystem's own parser
// ever disagrees with a naive reading of the same tokens.json format).

private func hexToRGB(_ hex: String) -> MarginaliaRGBAComponents {
    var chars = hex
    if chars.hasPrefix("#") {
        chars.removeFirst()
    }
    guard let value = UInt32(chars, radix: 16) else {
        preconditionFailure("MarginaliaTokenParityTests: malformed hex token '\(hex)'")
    }
    return MarginaliaRGBAComponents(
        red: Double((value & 0xFF0000) >> 16) / 255.0,
        green: Double((value & 0x00FF00) >> 8) / 255.0,
        blue: Double(value & 0x0000FF) / 255.0
    )
}

private func rgbaStringToComponents(_ rgba: String) -> MarginaliaRGBAComponents {
    let parts = rgba
        .replacingOccurrences(of: "rgba(", with: "")
        .replacingOccurrences(of: ")", with: "")
        .split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4 else {
        preconditionFailure("MarginaliaTokenParityTests: malformed rgba token '\(rgba)'")
    }
    return MarginaliaRGBAComponents(
        red: parts[0] / 255.0,
        green: parts[1] / 255.0,
        blue: parts[2] / 255.0,
        alpha: parts[3]
    )
}

/// Looks up the raw token string tokens.json declares for a role, or nil for
/// `selectionWash` (handled separately — it's rgba, not hex). An explicit, exhaustive
/// switch (mirroring `MarginaliaColorTokens.hex(for:)` in MarginaliaColor.swift) rather
/// than reflection, so a new `MarginaliaColorRole` case is a compile error here, not a
/// silent `nil`.
private func hexForRole( // swiftlint:disable:this cyclomatic_complexity
    _ role: MarginaliaColorRole,
    in palette: TokensJSONPalette
) -> String? {
    switch role {
    case .canvas: palette.canvas
    case .elevated: palette.elevated
    case .surface: palette.surface
    case .inkBody: palette.inkBody
    case .inkHeading: palette.inkHeading
    case .inkSecondary: palette.inkSecondary
    case .hairline: palette.hairline
    case .accent: palette.accent
    case .accentHover: palette.accentHover
    case .accentPressed: palette.accentPressed
    case .recordingRed: palette.recordingRed
    case .success: palette.success
    case .selectionWash: nil
    }
}

private let tolerance = 0.001

@Suite("Marginalia token parity (brand/tokens.json <-> DesignSystem)")
struct MarginaliaTokenParityTests {

    // MARK: Colors

    @Test(
        "every light-mode color role matches tokens.json",
        arguments: MarginaliaColorRole.allCases
    )
    func lightColorsMatch(role: MarginaliaColorRole) {
        let tokens = TokensJSONLocator.load()
        let expectedHex = hexForRole(role, in: tokens.modes.light)
        assertColorMatchesToken(
            role: role,
            resolvedFromTokens: expectedHex,
            palette: tokens.modes.light,
            scheme: .light
        )
    }

    @Test(
        "every dark-mode color role matches tokens.json",
        arguments: MarginaliaColorRole.allCases
    )
    func darkColorsMatch(role: MarginaliaColorRole) {
        let tokens = TokensJSONLocator.load()
        let expectedHex = hexForRole(role, in: tokens.modes.dark)
        assertColorMatchesToken(role: role, resolvedFromTokens: expectedHex, palette: tokens.modes.dark, scheme: .dark)
    }

    private func assertColorMatchesToken(
        role: MarginaliaColorRole,
        resolvedFromTokens hex: String?,
        palette paletteJSON: TokensJSONPalette,
        scheme: ColorScheme
    ) {
        let swiftRGB = swiftColorComponents(role: role, scheme: scheme)

        if role == .selectionWash {
            let expected = rgbaStringToComponents(paletteJSON.selectionWash)
            #expect(abs(swiftRGB.red - expected.red) < tolerance)
            #expect(abs(swiftRGB.green - expected.green) < tolerance)
            #expect(abs(swiftRGB.blue - expected.blue) < tolerance)
            #expect(abs(swiftRGB.alpha - expected.alpha) < tolerance)
        } else {
            guard let hex else {
                Issue.record("no hex token found for role \(role)")
                return
            }
            let expected = hexToRGB(hex)
            #expect(abs(swiftRGB.red - expected.red) < tolerance)
            #expect(abs(swiftRGB.green - expected.green) < tolerance)
            #expect(abs(swiftRGB.blue - expected.blue) < tolerance)
        }
    }

    /// Extracts the RGBA components AriKit actually resolves for a role, by re-parsing the
    /// same internal token source the DesignSystem builds its palette from. (SwiftUI
    /// `Color` does not expose its components losslessly cross-platform, so parity is
    /// checked against the token source of truth one layer down, not the opaque `Color`
    /// value.)
    private func swiftColorComponents(role: MarginaliaColorRole, scheme: ColorScheme) -> MarginaliaRGBAComponents {
        let tokens = scheme == .dark ? MarginaliaColorTokenSource.dark : MarginaliaColorTokenSource.light
        if role == .selectionWash {
            return MarginaliaColorParsing.rgbaComponents(tokens.selectionWashRGBA)
        }
        guard let hex = tokens.hex(for: role) else {
            preconditionFailure("MarginaliaTokenParityTests: no hex token for role \(role)")
        }
        return MarginaliaColorParsing.hexComponents(hex)
    }

    // MARK: Spacing

    @Test("spacing scale matches tokens.json spacing array")
    func spacingMatches() {
        let tokens = TokensJSONLocator.load()
        #expect(MarginaliaSpacing.allCases.count == tokens.spacing.count)
        for step in MarginaliaSpacing.allCases {
            #expect(Double(step.value) == Double(tokens.spacing[step.rawValue]))
        }
    }

    // MARK: Radii

    @Test("radii match tokens.json radii")
    func radiiMatch() {
        let tokens = TokensJSONLocator.load()
        #expect(Double(MarginaliaRadius.control.value) == Double(tokens.radii.control))
        #expect(Double(MarginaliaRadius.card.value) == Double(tokens.radii.card))
        #expect(Double(MarginaliaRadius.dialog.value) == Double(tokens.radii.dialog))
    }

    // MARK: Typography

    @Test(
        "each type ramp entry matches tokens.json typography.ramp",
        arguments: MarginaliaTextStyle.allCases
    )
    func typographyRampMatches(style: MarginaliaTextStyle) {
        let tokens = TokensJSONLocator.load()
        guard let jsonEntry = tokens.typography.ramp.first(where: { $0.style == style.rawValue }) else {
            Issue.record("tokens.json has no ramp entry for style \(style.rawValue)")
            return
        }
        let spec = style.spec
        #expect(spec.weightValue == jsonEntry.weight)
        #expect(Double(spec.sizePt) == Double(jsonEntry.sizePt))
        // Bricolage/SF Pro/SF Mono face names in tokens.json are the family; AriKit's
        // `spec.face` sometimes narrows to a specific member of that family (e.g.
        // "SF Pro Text" vs "SF Pro") — a prefix match on either side is intentional here,
        // not a laxness bug.
        let facesMatch = spec.face == jsonEntry.face
            || jsonEntry.face.hasPrefix(spec.face)
            || spec.face.hasPrefix(jsonEntry.face)
        #expect(facesMatch)

        #expect(spec.ink.rawValue == jsonEntry.ink)
        #expect(spec.trackingEm == jsonEntry.trackingEm)
        #expect(spec.isUppercase == (jsonEntry.transform == "uppercase"))
    }

    // MARK: Rules

    @Test("brand rule constants match tokens.json rules")
    func rulesMatch() {
        let tokens = TokensJSONLocator.load()
        #expect(MarginaliaRules.accentMaxCoverage == tokens.rules.accentMaxCoverage)
        #expect(MarginaliaRules.bricolageMinSizePt == Double(tokens.rules.bricolageMinSizePt))
        #expect(MarginaliaRules.markMinFullSizePx == Double(tokens.rules.markMinFullSizePx))
        #expect(MarginaliaRules.accentAllowedOn == tokens.rules.accentAllowedOn)
        #expect(MarginaliaRules.headingInkInteractive == tokens.rules.headingInkInteractive)
        #expect(MarginaliaRules.noFakeState == tokens.rules.noFakeState)
        #expect(MarginaliaRules.recordingAlwaysConsented == tokens.rules.recordingAlwaysConsented)
        #expect(MarginaliaRules.warmNeutralsOnly == tokens.rules.warmNeutralsOnly)
        // tokens.json encodes this rule as descriptive prose (`rules.accentSolidFill`),
        // not a boolean, so there's no literal value to assert equality against. The best
        // parity check available is that the prose is still present (the rule wasn't
        // dropped from tokens.json) — `MarginaliaRules.accentSolidFillExclusive` itself is
        // a hand-authored restatement of that prose as a boolean flag for code to branch
        // on, and can't be derived from the JSON value losslessly.
        #expect(!tokens.rules.accentSolidFill.isEmpty)
        #expect(MarginaliaRules.accentSolidFillExclusive == true)
    }
}
