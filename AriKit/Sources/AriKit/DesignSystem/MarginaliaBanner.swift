//
//  MarginaliaBanner.swift — inline toast/banner view (plan §5 Tier 1.6,
//  docs/plans/arikit-component-library.md).
//
//  Ships the inline VIEW now; the transient auto-dismiss presentation mechanism
//  (`.marginaliaToast` + `@Observable ToastCenter`) is explicitly DEFERRED (plan §8).
//
import SwiftUI

/// The three banner kinds in the Marginalia system (plan §5 Tier 1.6).
public enum MarginaliaBannerKind: Sendable {
    case info
    case success
    case error
}

/// Plain-data description of one banner kind's appearance, independent of `View` so the
/// parity test (`MarginaliaBannerStyleParityTests`) can assert the mapping directly.
public struct MarginaliaBannerSpec: Sendable, Equatable {
    public let symbol: String
    public let tint: MarginaliaColorRole

    public init(symbol: String, tint: MarginaliaColorRole) {
        self.symbol = symbol
        self.tint = tint
    }
}

public extension MarginaliaBannerKind {
    /// The declared appearance for this kind (plan §5 Tier 1.6).
    var spec: MarginaliaBannerSpec {
        switch self {
        case .info:
            MarginaliaBannerSpec(symbol: "info.circle", tint: .inkSecondary)
        case .success:
            MarginaliaBannerSpec(symbol: "checkmark.seal", tint: .success)
        case .error:
            MarginaliaBannerSpec(symbol: "exclamationmark.triangle", tint: .recordingRed)
        }
    }
}

/// An inline banner — always labeled (kind symbol + message), optional trailing action.
///
/// ```swift
/// MarginaliaBanner(kind: .success, message: "Speaker confirmed.", scheme: colorScheme)
/// ```
public struct MarginaliaBanner: View {
    private let kind: MarginaliaBannerKind
    private let message: String
    private let action: (title: String, handler: () -> Void)?
    private let scheme: ColorScheme

    public init(
        kind: MarginaliaBannerKind,
        message: String,
        action: (title: String, handler: () -> Void)? = nil,
        scheme: ColorScheme
    ) {
        self.kind = kind
        self.message = message
        self.action = action
        self.scheme = scheme
    }

    public var body: some View {
        let spec = kind.spec
        HStack(spacing: MarginaliaSpacing.sm.value) {
            Image(systemName: spec.symbol)
                .foregroundStyle(Color.marginalia(spec.tint, in: scheme))
            Text(message)
                .marginaliaTextStyle(.body, in: scheme)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.handler)
                    .buttonStyle(.marginalia(.quiet, .regular, in: scheme))
            }
        }
        .padding(MarginaliaSpacing.md.value)
        .background {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .fill(Color.marginalia(.surface, in: scheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MarginaliaRadius.card.value, style: .continuous)
                .strokeBorder(Color.marginalia(.hairline, in: scheme), lineWidth: 1)
        }
    }
}
