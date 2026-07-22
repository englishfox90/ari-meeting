//
//  VoiceprintRingTests.swift — ← TS port tests for `frontend/src/lib/voiceprint-glyph.ts`
//  (`buildVoiceprintRing`/`voiceprintColors`), adapted to the pure numeric API
//  (`ringRadii`/`color`) that AriViewModels exposes (no SwiftUI/CoreGraphics).
//
import Testing
@testable import AriViewModels

@Suite("VoiceprintRing")
struct VoiceprintRingTests {

    // MARK: - ringRadii

    @Test
    func ringRadiiCountMatchesInput() {
        let values: [Float] = [0.0, 0.5, 1.0, 0.25, 0.75]
        let radii = VoiceprintRing.ringRadii(values)
        #expect(radii?.count == values.count)
    }

    @Test
    func ringRadiiWithinExpectedBand() throws {
        let values: [Float] = (0 ..< 32).map { Float($0) / 31.0 }
        let radii = try #require(VoiceprintRing.ringRadii(values))
        #expect(radii.allSatisfy { $0 >= 0.46 && $0 <= 0.94 })
    }

    @Test
    func ringRadiiEndpointsHitMinAndMax() throws {
        let values: [Float] = [0.0, 0.5, 1.0]
        let radii = try #require(VoiceprintRing.ringRadii(values))
        #expect(abs(radii[0] - 0.46) < 1e-9)
        #expect(abs(radii[2] - 0.94) < 1e-9)
    }

    @Test
    func ringRadiiClampsOutOfRangeValues() throws {
        let values: [Float] = [-1.0, 0.5, 2.0]
        let radii = try #require(VoiceprintRing.ringRadii(values))
        #expect(abs(radii[0] - 0.46) < 1e-9) // clamped to 0
        #expect(abs(radii[2] - 0.94) < 1e-9) // clamped to 1
    }

    @Test
    func ringRadiiNilBelowThreeValues() {
        #expect(VoiceprintRing.ringRadii([]) == nil)
        #expect(VoiceprintRing.ringRadii([0.5]) == nil)
        #expect(VoiceprintRing.ringRadii([0.5, 0.5]) == nil)
    }

    // MARK: - color

    @Test
    func colorNilBelowThreeValues() {
        #expect(VoiceprintRing.color([], dark: true) == nil)
        #expect(VoiceprintRing.color([0.5], dark: true) == nil)
        #expect(VoiceprintRing.color([0.5, 0.5], dark: true) == nil)
    }

    @Test
    func colorIsDeterministic() {
        let values: [Float] = (0 ..< 32).map { Float($0 * 7 % 32) / 31.0 }
        let a = VoiceprintRing.color(values, dark: true)
        let b = VoiceprintRing.color(values, dark: true)
        #expect(a == b)
    }

    @Test
    func colorSaturationInExpectedBand() throws {
        let values: [Float] = (0 ..< 32).map { Float($0 * 7 % 32) / 31.0 }
        let color = try #require(VoiceprintRing.color(values, dark: true))
        #expect(color.saturation >= 46 && color.saturation <= 64)
    }

    @Test
    func colorLightnessDiffersByTheme() throws {
        let values: [Float] = (0 ..< 32).map { Float($0 * 7 % 32) / 31.0 }
        let dark = try #require(VoiceprintRing.color(values, dark: true))
        let light = try #require(VoiceprintRing.color(values, dark: false))
        #expect(dark.lightness == 66)
        #expect(light.lightness == 40)
        #expect(dark.lightness != light.lightness)
        // Hue/saturation projection is theme-independent.
        #expect(dark.hueFrom == light.hueFrom)
        #expect(dark.saturation == light.saturation)
    }

    @Test
    func colorHuesWithinDegreeRange() throws {
        let values: [Float] = (0 ..< 32).map { Float($0 * 3 % 32) / 31.0 }
        let color = try #require(VoiceprintRing.color(values, dark: true))
        #expect(color.hueFrom >= 0 && color.hueFrom < 360)
        #expect(color.hueTo >= 0 && color.hueTo < 360)
    }

    @Test
    func colorPeakedSignatureYieldsHighSaturation() throws {
        // All energy in one bucket → primary concentration (mag) near 1 → saturation near 64.
        var values = [Float](repeating: 0.0, count: 32)
        values[0] = 1.0
        let color = try #require(VoiceprintRing.color(values, dark: true))
        #expect(color.saturation >= 60)
    }
}
