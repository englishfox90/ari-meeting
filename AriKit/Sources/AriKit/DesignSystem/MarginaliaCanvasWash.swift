//
//  MarginaliaCanvasWash.swift — the ambient canvas ground (Liquid Glass v2,
//  docs/plans/liquid-glass-adoption.md).
//
//  A single, very gentle diagonal wash between the two existing paper grounds
//  (`.canvas` → `.elevated`) used as the window-content background instead of flat
//  `.canvas`. Its whole job is to give the system's Liquid Glass chrome (sidebar,
//  toolbar, floating controls) tonal variation to refract — flat one-color grounds
//  make glass read as an opaque panel.
//
//  This is the ONE sanctioned gradient in Marginalia (owner decision 2026-07-21,
//  revising the BRAND.md §4 "no gradients" rule). It is built exclusively from the
//  two existing ground tokens — both already valid contrast grounds for every ink —
//  so it introduces no new color and no new contrast risk. Never add further
//  gradients, and never put this wash on cards, fields, or controls.
//
import SwiftUI

/// The ambient window-content ground: `.canvas` (top leading) → `.elevated`
/// (bottom trailing), in the given scheme. Use in place of a flat
/// `Color.marginalia(.canvas, in:)` page background.
public struct MarginaliaCanvasWash: View {
    private let scheme: ColorScheme

    public init(scheme: ColorScheme) {
        self.scheme = scheme
    }

    public var body: some View {
        LinearGradient(
            colors: [
                Color.marginalia(.canvas, in: scheme),
                Color.marginalia(.elevated, in: scheme),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
