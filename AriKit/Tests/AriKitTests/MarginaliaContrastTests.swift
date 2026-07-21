//
//  MarginaliaContrastTests.swift — WCAG on-fill contrast assertions (design review finding
//  #20). Locks the on-fill readability the review verified: labels/icons drawn directly on
//  a solid fill (buttons, badges) must clear WCAG AA (4.5:1) in both color schemes.
//
//  Computed from the resolved token hexes via a small local sRGB relative-luminance /
//  contrast-ratio helper — deliberately independent of any production contrast utility, so
//  this suite can't silently pass because of a shared bug.
//
import Foundation
import Testing
@testable import AriKit

// MARK: - WCAG contrast helper (local to this test file)

private enum WCAGContrast {
    /// Converts one sRGB 0...1 channel to linear light, per the WCAG 2.x relative
    /// luminance formula.
    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2.x relative luminance of an sRGB color.
    static func relativeLuminance(_ components: MarginaliaRGBAComponents) -> Double {
        let red = linearize(components.red)
        let green = linearize(components.green)
        let blue = linearize(components.blue)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// WCAG 2.x contrast ratio between two colors (order-independent), 1:1...21:1.
    static func ratio(_ first: MarginaliaRGBAComponents, _ second: MarginaliaRGBAComponents) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

private let wcagAA: Double = 4.5

@Suite("Marginalia on-fill contrast (WCAG AA, both schemes)")
struct MarginaliaContrastTests {

    private func components(_ role: MarginaliaColorRole, tokens: MarginaliaColorTokens) -> MarginaliaRGBAComponents {
        if role == .selectionWash {
            return MarginaliaColorParsing.rgbaComponents(tokens.selectionWashRGBA)
        }
        guard let hex = tokens.hex(for: role) else {
            preconditionFailure("MarginaliaContrastTests: no hex token for role \(role)")
        }
        return MarginaliaColorParsing.hexComponents(hex)
    }

    private func assertOnFillContrast(
        label: MarginaliaColorRole,
        fill: MarginaliaColorRole,
        tokens: MarginaliaColorTokens,
        schemeName: String
    ) {
        let labelComponents = components(label, tokens: tokens)
        let fillComponents = components(fill, tokens: tokens)
        let ratio = WCAGContrast.ratio(labelComponents, fillComponents)
        #expect(
            ratio >= wcagAA,
            "\(label) on \(fill) (\(schemeName)) contrast \(ratio) < \(wcagAA)"
        )
    }

    @Test("canvas-on-accent clears AA in light and dark")
    func canvasOnAccent() {
        assertOnFillContrast(
            label: .canvas, fill: .accent, tokens: MarginaliaColorTokenSource.light, schemeName: "light"
        )
        assertOnFillContrast(
            label: .canvas, fill: .accent, tokens: MarginaliaColorTokenSource.dark, schemeName: "dark"
        )
    }

    @Test("canvas-on-recordingRed clears AA in light and dark")
    func canvasOnRecordingRed() {
        assertOnFillContrast(
            label: .canvas, fill: .recordingRed, tokens: MarginaliaColorTokenSource.light, schemeName: "light"
        )
        assertOnFillContrast(
            label: .canvas, fill: .recordingRed, tokens: MarginaliaColorTokenSource.dark, schemeName: "dark"
        )
    }

    @Test("canvas-on-success clears AA in light and dark")
    func canvasOnSuccess() {
        assertOnFillContrast(
            label: .canvas, fill: .success, tokens: MarginaliaColorTokenSource.light, schemeName: "light"
        )
        assertOnFillContrast(
            label: .canvas, fill: .success, tokens: MarginaliaColorTokenSource.dark, schemeName: "dark"
        )
    }

    @Test("inkSecondary-on-elevated clears AA in light and dark")
    func inkSecondaryOnElevated() {
        assertOnFillContrast(
            label: .inkSecondary, fill: .elevated, tokens: MarginaliaColorTokenSource.light, schemeName: "light"
        )
        assertOnFillContrast(
            label: .inkSecondary, fill: .elevated, tokens: MarginaliaColorTokenSource.dark, schemeName: "dark"
        )
    }
}
