//
//  MarginaliaToggleRow.swift — labeled toggle row (plan §5 Tier 1.5,
//  docs/plans/arikit-component-library.md).
//
//  A stock `Toggle(.switch)`. The app root SHOULD apply the global `.tint(AccentShinKai)`
//  (BRAND.md §10) — that wiring lands in the app-screens wave, not here — and once it does,
//  this switch inherits the tint for free; do not hand-color it in the meantime. Gallery-only
//  coverage: nothing to lock beyond the type-ramp roles already covered by
//  MarginaliaTokenParityTests.
//
import SwiftUI

/// A titled toggle with an optional secondary description line, themed purely via the
/// Marginalia type ramp — the switch itself takes its color from the app's global tint.
public struct MarginaliaToggleRow: View {
    private let title: String
    private let description: String?
    private let isOn: Binding<Bool>
    private let scheme: ColorScheme

    public init(_ title: String, description: String? = nil, isOn: Binding<Bool>, scheme: ColorScheme) {
        self.title = title
        self.description = description
        self.isOn = isOn
        self.scheme = scheme
    }

    public var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: MarginaliaSpacing.xs.value) {
                Text(title)
                    .marginaliaTextStyle(.body, in: scheme)
                if let description {
                    Text(description)
                        .marginaliaTextStyle(.callout, in: scheme)
                }
            }
        }
        .toggleStyle(.switch)
    }
}
