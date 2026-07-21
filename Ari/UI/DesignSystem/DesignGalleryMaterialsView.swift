#if DEBUG
//
//  DesignGalleryMaterialsView.swift — section 7 of `DesignGalleryView` (DEBUG only), and the
//  key one: BRAND.md §4/§9 say Marginalia's translucency comes ONLY from stock macOS
//  materials, never a hand-rolled glass effect. This section renders the real system
//  materials — including a genuinely live `NavigationSplitView` sidebar — and, separately, a
//  macOS 26 Liquid Glass demo (the `glassEffect` API) so the owner can evaluate it against the
//  stock-materials-only rule; it is NOT adopted anywhere in Marginalia today.
//
import AriKit
import SwiftUI

struct DesignGalleryMaterialsSection: View {
    let scheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.md.value) {
            SectionHeader(title: "SYSTEM MATERIALS")

            Text(
                "Stock NavigationSplitView sidebar = system Liquid Glass material (BRAND.md §10). "
                    + "Marginalia never hand-rolls glass."
            )
            .marginaliaTextStyle(.callout, in: scheme)

            MaterialsNavigationDemo()
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                        .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
                )

            Text("Stock SwiftUI materials (translucency over a busy ground)")
                .marginaliaTextStyle(.callout, in: scheme)
            materialSwatches

            liquidGlassSection
        }
    }

    // MARK: - Stock material swatches

    private var materialSwatches: some View {
        HStack(spacing: MarginaliaSpacing.md.value) {
            materialSwatch(.ultraThinMaterial, name: "ultraThin")
            materialSwatch(.thinMaterial, name: "thin")
            materialSwatch(.regularMaterial, name: "regular")
            materialSwatch(.thickMaterial, name: "thick")
            materialSwatch(.bar, name: "bar")
        }
    }

    private func materialSwatch(_ material: Material, name: String) -> some View {
        VStack(spacing: MarginaliaSpacing.xs.value) {
            ZStack {
                busyGround
                RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                    .fill(material)
            }
            .frame(width: 90, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous))
            Text(name)
                .marginaliaTextStyle(.timecode, in: scheme)
        }
    }

    /// A busy ground purely so translucency is visible in the swatches/glass demos below —
    /// gradients are otherwise off-limits in Marginalia product surfaces (BRAND.md §4), but
    /// this debug-only validator needs contrast behind the stock materials to show the effect.
    private var busyGround: some View {
        LinearGradient(
            colors: [
                Color.marginalia(.accent, in: scheme),
                Color.marginalia(.recordingRed, in: scheme),
                Color.marginalia(.success, in: scheme),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Liquid Glass (macOS 26, evaluation only)

    private var liquidGlassSection: some View {
        VStack(alignment: .leading, spacing: MarginaliaSpacing.sm.value) {
            Text("macOS 26 Liquid Glass (glassEffect) — NOT currently adopted in Marginalia; shown so you can evaluate it.")
                .marginaliaTextStyle(.callout, in: scheme)

            ZStack {
                busyGround
                GlassEffectContainer(spacing: MarginaliaSpacing.md.value) {
                    HStack(spacing: MarginaliaSpacing.md.value) {
                        Text("Capsule")
                            .marginaliaTextStyle(.body, in: scheme)
                            .padding(.horizontal, MarginaliaSpacing.lg.value)
                            .padding(.vertical, MarginaliaSpacing.sm.value)
                            .glassEffect(.regular, in: Capsule())

                        Image(systemName: "mic.fill")
                            .font(.system(size: 20))
                            // Paper (`.canvas`), not `.accent`: the glass is tinted `.accent`, so an
                            // accent icon on it has no contrast — the same on-fill rule as the buttons.
                            .foregroundStyle(Color.marginalia(.canvas, in: scheme))
                            .padding(MarginaliaSpacing.md.value)
                            .glassEffect(.regular.tint(Color.marginalia(.accent, in: scheme)), in: Circle())
                    }
                }
            }
            .padding(MarginaliaSpacing.lg.value)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous))
        }
    }
}

/// A live, stock `NavigationSplitView` (Label rows, SF Symbols only) so the real system
/// sidebar material renders — the point of this whole section.
private struct MaterialsNavigationDemo: View {
    @State private var selection: String? = "Home"

    private let items: [(name: String, symbol: String)] = [
        ("Home", "house"),
        ("Meetings", "list.bullet.rectangle"),
        ("People", "person.2"),
        ("Series", "calendar"),
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(items, id: \.name) { item in
                    Label(item.name, systemImage: item.symbol)
                        .tag(item.name)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            VStack {
                Text(selection ?? "Select an item")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
