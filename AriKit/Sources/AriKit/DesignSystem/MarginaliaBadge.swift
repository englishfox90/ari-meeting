//
//  MarginaliaBadge.swift — the Marginalia badge/chip system (plan §5 Tier 1.4,
//  docs/plans/arikit-component-library.md).
//
//  Four styles: neutral, accent (the citation/selection look — accent-allowed), success,
//  recording. `MarginaliaBadgeSpec` is a plain-data description kept separate from the
//  `View` so the parity test can assert the style -> color-role / symbol mapping directly,
//  mirroring `MarginaliaButtonSpec`/`MarginaliaButtonStyleParityTests`.
//
import SwiftUI

/// The four badge styles in the Marginalia system (plan §5 Tier 1.4).
public enum MarginaliaBadgeStyle: Sendable {
    case neutral
    case accent
    case success
    case recording
}

/// Plain-data description of one badge style's appearance, independent of `View` so the
/// parity test (`MarginaliaBadgeStyleParityTests`) can assert the mapping directly.
public struct MarginaliaBadgeSpec: Sendable, Equatable {
    /// Fill color role — `nil` means no fill (accent style is a selection wash, still a fill).
    public let fill: MarginaliaColorRole?
    /// Label/foreground color role.
    public let label: MarginaliaColorRole
    /// Stroke color role — `nil` means no stroke.
    public let stroke: MarginaliaColorRole?
    /// A symbol this style REQUIRES (success/recording carry a fixed meaning symbol);
    /// `nil` means the caller supplies whatever symbol fits the content.
    public let requiredSymbol: String?

    public init(
        fill: MarginaliaColorRole?,
        label: MarginaliaColorRole,
        stroke: MarginaliaColorRole?,
        requiredSymbol: String?
    ) {
        self.fill = fill
        self.label = label
        self.stroke = stroke
        self.requiredSymbol = requiredSymbol
    }
}

public extension MarginaliaBadgeStyle {
    /// The declared appearance for this style (plan §5 Tier 1.4).
    var spec: MarginaliaBadgeSpec {
        switch self {
        case .neutral:
            MarginaliaBadgeSpec(fill: .elevated, label: .inkSecondary, stroke: .hairline, requiredSymbol: nil)
        case .accent:
            // The citation/selection look — accent-allowed per plan §7 Signal Rule carve-out.
            MarginaliaBadgeSpec(fill: .selectionWash, label: .accent, stroke: nil, requiredSymbol: nil)
        case .success:
            MarginaliaBadgeSpec(fill: .success, label: .canvas, stroke: nil, requiredSymbol: "checkmark.seal")
        case .recording:
            MarginaliaBadgeSpec(fill: .recordingRed, label: .canvas, stroke: nil, requiredSymbol: "record.circle")
        }
    }
}

/// A tappable-or-static Marginalia badge/chip.
///
/// ```swift
/// MarginaliaBadge("Confirmed", style: .success, scheme: colorScheme)
/// MarginaliaBadge("[S1]", style: .accent, symbol: "text.quote", scheme: colorScheme) { select(source) }
/// ```
public struct MarginaliaBadge: View {
    private let title: String
    private let style: MarginaliaBadgeStyle
    private let symbol: String?
    private let scheme: ColorScheme
    private let action: (() -> Void)?

    public init(
        _ title: String,
        style: MarginaliaBadgeStyle,
        symbol: String? = nil,
        scheme: ColorScheme,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.style = style
        self.symbol = symbol
        self.scheme = scheme
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        let spec = style.spec
        return HStack(spacing: MarginaliaSpacing.xs.value) {
            if let resolvedSymbol = spec.requiredSymbol ?? symbol {
                Image(systemName: resolvedSymbol)
            }
            Text(title)
        }
        .marginaliaTextStyle(.callout, in: scheme, ink: spec.label)
        .padding(.horizontal, MarginaliaSpacing.sm.value)
        .padding(.vertical, MarginaliaSpacing.xs.value)
        .background {
            if let fill = spec.fill {
                RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                    .fill(Color.marginalia(fill, in: scheme))
            }
        }
        .overlay {
            if let stroke = spec.stroke {
                RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                    .strokeBorder(Color.marginalia(stroke, in: scheme), lineWidth: 1)
            }
        }
    }
}
