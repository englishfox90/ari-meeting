//
//  MarginaliaTextStyleModifier.swift — one-call type-ramp application for SwiftUI views.
//
//  Bundles the three things a view otherwise has to re-derive by hand for every piece of
//  text: the ramp entry's `Font`, its ink color (resolved for the current `ColorScheme`),
//  and its letter tracking (only non-nil for `.caption` today). Phase 2 screens should
//  reach for this instead of composing `.font` / `.foregroundStyle` / `.tracking` per call
//  site.
//
import SwiftUI

public extension View {
    /// Applies a Marginalia type-ramp entry — font, ink, and (where declared) letter
    /// tracking — in one call.
    ///
    /// ```swift
    /// Text("RECORDING")
    ///     .marginaliaTextStyle(.caption, in: colorScheme)
    /// ```
    func marginaliaTextStyle(_ style: MarginaliaTextStyle, in scheme: ColorScheme) -> some View {
        font(style.font)
            .foregroundStyle(Color.marginalia(style.spec.ink, in: scheme))
            .modifier(MarginaliaTrackingModifier(points: style.trackingPoints))
    }
}

/// Applies `.tracking(_:)` only when the ramp entry declares a value — kept as a small
/// separate modifier so the optional doesn't force `body`'s return type to branch between
/// two different `some View` shapes.
private struct MarginaliaTrackingModifier: ViewModifier {
    let points: CGFloat?

    func body(content: Content) -> some View {
        if let points {
            content.tracking(points)
        } else {
            content
        }
    }
}
