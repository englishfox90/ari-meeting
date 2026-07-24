//
//  ToolbarScrollFade.swift — the top-edge treatment for scroll views that run under the
//  floating window toolbar.
//
//  The app uses a frameless / unified title bar (`.windowStyle(.hiddenTitleBar)`), so content
//  scrolls all the way to the window's top edge and passes BEHIND the toolbar's glass. Neither
//  stock `ScrollEdgeEffectStyle` was right on its own, measured on macOS 26:
//
//  - `.soft` — a gentle progressive fade, but body text stays plainly legible as it slides behind
//    and between the toolbar buttons, colliding with the controls.
//  - `.hard` — opaque and legible, but it clips content mid-glyph at a dead-straight line.
//
//  This fades the CONTENT ITSELF to transparent before it reaches the controls, so the toolbar
//  glass refracts the plain canvas ground instead of half a sentence. It is an alpha mask, not a
//  painted gradient: it introduces no new color and no new fill, so the Marginalia "exactly one
//  gradient — the canvas wash" rule (BRAND.md §4) still holds. The system's `.soft` effect stays
//  on underneath for its blur.
//
import SwiftUI

extension View {
    /// Fades this scroll view's content out beneath the floating window toolbar.
    ///
    /// Apply to a `ScrollView` whose top edge sits under the toolbar. Content is fully
    /// transparent through the toolbar band, ramps back to fully opaque just below it, and is
    /// untouched from there down.
    func toolbarScrollFade() -> some View {
        mask {
            VStack(spacing: 0) {
                // Behind the controls: content is entirely hidden, so nothing reads through the
                // glass. Matches the toolbar's measured button band (~52pt tall).
                Color.clear
                    .frame(height: 46)
                // The soft part: content ramps in over this band instead of being cut at a line.
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 30)
                Color.black
            }
            .ignoresSafeArea()
        }
    }
}
