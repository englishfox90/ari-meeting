//
//  MarginaliaMenuLabel.swift — themed closed-state dropdown label (plan §5 Tier 1.2,
//  docs/plans/arikit-component-library.md).
//
//  Callers use stock `Picker(.menu)` (bound selection) or stock `Menu { } label: { … } `
//  (actions) — this is only the themed label, matching `MarginaliaTextField`'s surface.
//  The popover itself is stock system material.
//
import SwiftUI

/// A themed label for a dropdown's closed state — title + chevron, `MarginaliaFieldSpec
/// .standard` surface. Wrap it in `Picker(.menu)` or `Menu { … } label: { … }`.
///
/// ```swift
/// Menu {
///     Button("Rename") { … }
/// } label: {
///     MarginaliaMenuLabel(title: "Actions", scheme: colorScheme)
/// }
/// ```
public struct MarginaliaMenuLabel: View {
    /// The chevron symbol every Marginalia dropdown label shares.
    public static let chevronSymbol = "chevron.up.chevron.down"

    private let title: String
    private let scheme: ColorScheme

    public init(title: String, scheme: ColorScheme) {
        self.title = title
        self.scheme = scheme
    }

    public var body: some View {
        HStack(spacing: MarginaliaSpacing.xs.value) {
            Text(title)
                .marginaliaTextStyle(.body, in: scheme)
            Spacer(minLength: 0)
            Image(systemName: Self.chevronSymbol)
                .foregroundStyle(Color.marginalia(.inkSecondary, in: scheme))
        }
        .padding(.horizontal, MarginaliaSpacing.sm.value)
        .frame(height: MarginaliaFieldSpec.standard.height)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous)
                .fill(Color.marginalia(MarginaliaFieldSpec.standard.fill, in: scheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MarginaliaFieldSpec.standard.radius.value, style: .continuous)
                .strokeBorder(Color.marginalia(MarginaliaFieldSpec.standard.stroke, in: scheme), lineWidth: 1)
        }
    }
}
