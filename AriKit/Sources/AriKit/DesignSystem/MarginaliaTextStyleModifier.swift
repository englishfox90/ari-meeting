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
        marginaliaTextStyle(style, in: scheme, ink: style.spec.ink)
    }

    /// Same as `marginaliaTextStyle(_:in:)` but with an explicit ink role, for the cases
    /// where a component needs a non-default foreground (a button/badge label on a colored
    /// fill, an error line in `.recordingRed`, an accent link).
    ///
    /// USE THIS instead of `.marginaliaTextStyle(style, in:).foregroundStyle(ink)` — that
    /// pattern is a silent trap: `marginaliaTextStyle` already sets the text's foreground to
    /// the style's *default* ink, and SwiftUI resolves a `Text`'s color from the INNERMOST
    /// `foregroundStyle`, so the trailing override never wins and the default ink renders
    /// instead. Folding the ink into one modifier is the only correct form.
    func marginaliaTextStyle(
        _ style: MarginaliaTextStyle,
        in scheme: ColorScheme,
        ink: MarginaliaColorRole
    ) -> some View {
        font(style.font)
            .foregroundStyle(Color.marginalia(ink, in: scheme))
            .modifier(MarginaliaTrackingModifier(points: style.trackingPoints))
            .modifier(MarginaliaUppercaseModifier(isUppercase: style.spec.isUppercase))
    }
}

/// Applies `.textCase(.uppercase)` only when the ramp entry declares the transform (only
/// `.caption` today) — kept as a small separate modifier so the conditional doesn't force
/// `body`'s return type to branch between two different `some View` shapes, mirroring
/// `MarginaliaTrackingModifier` above.
private struct MarginaliaUppercaseModifier: ViewModifier {
    let isUppercase: Bool

    func body(content: Content) -> some View {
        if isUppercase {
            content.textCase(.uppercase)
        } else {
            content
        }
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
