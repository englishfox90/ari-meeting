#if DEBUG
//
//  DesignGalleryView.swift — DEBUG-only Marginalia design-system validator: colors, type,
//  buttons, spacing, components, and the real macOS system materials / Liquid Glass.
//
//  Composes already-tested AriKit design-system primitives visually so the owner can eyeball
//  every token and — critically — the real stock materials Marginalia's "glass" comes from
//  (BRAND.md §4/§9: "no glassmorphism of our own"). Never shipped in release: this file and
//  the scene that hosts it (`AriApp.swift`) are both wrapped in `#if DEBUG`.
//
//  Split across a few files in this folder (all auto-included — `Ari/UI/` is a
//  PBXFileSystemSynchronizedRootGroup): this file (header, colors, typography),
//  `DesignGalleryButtonsView.swift` (buttons, spacing/radii), `DesignGalleryComponentsView.swift`
//  (SectionHeader/CardRow/StateContainer), `DesignGalleryMaterialsView.swift` (system materials
//  + Liquid Glass).
//
import AppKit
import AriKit
import AriViewModels
import SwiftUI

struct DesignGalleryView: View {
    @State private var previewScheme: ColorScheme = .light
    @State private var glassEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xxl.value) {
                headerSection
                colorSection
                typographySection
                DesignGalleryButtonsSection(scheme: previewScheme, glass: glassEnabled)
                DesignGalleryPrimitivesSection(scheme: previewScheme, glass: glassEnabled)
                DesignGallerySpacingSection(scheme: previewScheme)
                DesignGalleryComponentsSection(scheme: previewScheme, glass: glassEnabled)
                DesignGalleryMaterialsSection(scheme: previewScheme)
            }
            .padding(MarginaliaSpacing.xl.value)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.marginalia(.canvas, in: previewScheme))
        .preferredColorScheme(previewScheme)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("Marginalia")
                .marginaliaTextStyle(.display, in: previewScheme)
            Text("Design system validator")
                .marginaliaTextStyle(.callout, in: previewScheme)

            Picker("Preview scheme", selection: $previewScheme) {
                Text("Light").tag(ColorScheme.light)
                Text("Dark").tag(ColorScheme.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .padding(.top, MarginaliaSpacing.xs.value)

            Toggle("Preview components with Liquid Glass", isOn: $glassEnabled)
                .toggleStyle(.switch)
                .marginaliaTextStyle(.callout, in: previewScheme)
                .padding(.top, MarginaliaSpacing.xs.value)
        }
    }

    // MARK: - Color roles

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "COLOR ROLES")
            VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
                ForEach(MarginaliaColorRole.allCases, id: \.self) { role in
                    colorRow(role)
                }
            }
        }
    }

    private func colorRow(_ role: MarginaliaColorRole) -> some View {
        HStack(spacing: MarginaliaSpacing.md.value) {
            swatch(MarginaliaColors.light[role])
            swatch(MarginaliaColors.dark[role])
            VStack(alignment: .leading, spacing: 2) {
                Text(role.rawValue)
                    .marginaliaTextStyle(.body, in: previewScheme)
                if let lightHex = hexString(MarginaliaColors.light[role]),
                   let darkHex = hexString(MarginaliaColors.dark[role]) {
                    Text("light \(lightHex) · dark \(darkHex)")
                        .marginaliaTextStyle(.timecode, in: previewScheme)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
            .fill(color)
            .frame(width: 56, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                    .strokeBorder(Color.marginalia(.hairline, in: previewScheme), lineWidth: 1)
            )
    }

    /// Reads a `Color`'s sRGB components via `NSColor` for a debug-only hex readout. Not part
    /// of AriKit's public surface — this is a gallery-only convenience, never product code.
    private func hexString(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    // MARK: - Typography

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "TYPOGRAPHY")
            VStack(alignment: .leading, spacing: MarginaliaSpacing.lg.value) {
                ForEach(MarginaliaTextStyle.allCases, id: \.self) { style in
                    typographyRow(style)
                }
            }
        }
    }

    private func typographyRow(_ style: MarginaliaTextStyle) -> some View {
        let spec = style.spec
        return VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
            Text("The record that remembers your people")
                .marginaliaTextStyle(style, in: previewScheme)
            Text("\(spec.face) · \(spec.weightValue) · \(Int(spec.sizePt))pt")
                .marginaliaTextStyle(.timecode, in: previewScheme)
        }
    }
}

/// Reusable flat ⇄ Liquid Glass surface treatment for gallery container components (the
/// Components card, the Buttons panel), so the `glassEnabled` toggle in `DesignGalleryView`
/// visibly swaps real Marginalia surfaces between the current flat treatment and macOS 26
/// `glassEffect`. Debug-only, gallery-only — never product code.
private struct GalleryComponentSurface: ViewModifier {
    let glass: Bool
    let scheme: ColorScheme
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if glass {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(Color.marginalia(.surface, in: scheme))
                .overlay(shape.strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1))
                .clipShape(shape)
        }
    }
}

extension View {
    /// Applies `GalleryComponentSurface` — flat Marginalia fill+hairline when `glass` is
    /// `false`, stock `glassEffect` when `true`. `shape` defaults to the standard card radius.
    func galleryComponentSurface(
        glass: Bool,
        scheme: ColorScheme,
        shape: RoundedRectangle = RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
    ) -> some View {
        modifier(GalleryComponentSurface(glass: glass, scheme: scheme, shape: shape))
    }
}
#endif
