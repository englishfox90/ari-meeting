//
//  MarginaliaButtonStyle.swift — the Marginalia button system (plan §4,
//  docs/plans/arikit-native-read-ui.md).
//
//  Four roles x two sizes. `MarginaliaButtonSpec` is a plain-data description of a role
//  (its fill/label color roles + control height) kept separate from `MarginaliaButtonStyle`
//  itself so the parity test can assert the role -> color-role / size -> height mapping
//  without introspecting an opaque `ButtonStyle`.
//
//  "Exactly one Primary per view" (plan §4) is a reviewer-checklist invariant, not
//  statically enforceable from this file.
//
import SwiftUI

/// The four button roles in the Marginalia system (plan §4).
public enum MarginaliaButtonRole: Sendable, Equatable {
    case primary
    case secondary
    case quiet
    case recording
}

/// The two control heights a Marginalia button renders at (plan §4).
public enum MarginaliaButtonSize: Sendable {
    /// 26pt — toolbar/inline controls.
    case regular
    /// 32pt — dialog/HUD controls.
    case large

    public var controlHeight: CGFloat {
        switch self {
        case .regular: 26
        case .large: 32
        }
    }
}

/// Plain-data description of one role's appearance, independent of `ButtonStyle`/`View` so
/// the parity test (`MarginaliaButtonStyleParityTests`) can assert the mapping directly.
public struct MarginaliaButtonSpec: Sendable, Equatable {
    /// Fill color role — `nil` means no fill (the `quiet` role is fill-less).
    public let fill: MarginaliaColorRole?
    /// Label/foreground color role.
    public let label: MarginaliaColorRole
    /// Stroke color role — `nil` means no stroke.
    public let stroke: MarginaliaColorRole?
    /// The color role used for the pressed-state visual.
    public let pressed: MarginaliaColorRole

    public init(
        fill: MarginaliaColorRole?,
        label: MarginaliaColorRole,
        stroke: MarginaliaColorRole?,
        pressed: MarginaliaColorRole
    ) {
        self.fill = fill
        self.label = label
        self.stroke = stroke
        self.pressed = pressed
    }
}

public extension MarginaliaButtonRole {
    /// The declared appearance for this role (plan §4 table).
    var spec: MarginaliaButtonSpec {
        switch self {
        case .primary:
            // Label is `.canvas` (paper), NOT `.surface`: `.canvas` is near-white in light and
            // near-black in dark, so it stays high-contrast against the solid accent fill in BOTH
            // schemes. `.surface` resolves to warm-espresso (#2D2925) in dark mode, which reads as
            // muddy brown text on the light dark-mode accent fill.
            MarginaliaButtonSpec(fill: .accent, label: .canvas, stroke: nil, pressed: .accentPressed)
        case .secondary:
            MarginaliaButtonSpec(fill: .elevated, label: .inkBody, stroke: .hairline, pressed: .selectionWash)
        case .quiet:
            MarginaliaButtonSpec(fill: nil, label: .accent, stroke: nil, pressed: .selectionWash)
        case .recording:
            // `.canvas` label for the same contrast reason as `.primary` (see above): the dark-mode
            // recording-red fill (#FF6B5E) is light, so it needs near-black paper text, not `.surface`.
            MarginaliaButtonSpec(fill: .recordingRed, label: .canvas, stroke: nil, pressed: .recordingRed)
        }
    }
}

/// The Marginalia `ButtonStyle`: role + size + scheme resolve into fill/label/stroke/radius.
///
/// ```swift
/// Button("Copy summary") { … }
///     .buttonStyle(.marginalia(.quiet, .regular, in: colorScheme))
/// ```
public struct MarginaliaButtonStyle: ButtonStyle {
    let role: MarginaliaButtonRole
    let size: MarginaliaButtonSize
    let scheme: ColorScheme

    public init(role: MarginaliaButtonRole, size: MarginaliaButtonSize, scheme: ColorScheme) {
        self.role = role
        self.size = size
        self.scheme = scheme
    }

    public func makeBody(configuration: Configuration) -> some View {
        let spec = role.spec
        let isPressed = configuration.isPressed

        configuration.label
            .marginaliaTextStyle(.callout, in: scheme, ink: spec.label)
            .frame(height: size.controlHeight)
            .padding(.horizontal, MarginaliaSpacing.md.value)
            .background {
                RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                    .fill(fillColor(spec: spec, isPressed: isPressed))
            }
            .overlay {
                if let stroke = spec.stroke {
                    RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)
                        .strokeBorder(Color.marginalia(stroke, in: scheme), lineWidth: 1)
                }
            }
    }

    private func fillColor(spec: MarginaliaButtonSpec, isPressed: Bool) -> Color {
        guard isPressed else {
            guard let fill = spec.fill else { return .clear }
            return Color.marginalia(fill, in: scheme)
        }
        // `quiet` has no base fill; its pressed state is a wash overlay instead of a
        // darkened solid fill.
        return Color.marginalia(spec.pressed, in: scheme)
    }
}

public extension ButtonStyle where Self == MarginaliaButtonStyle {
    /// Ergonomic call-site sugar: `.buttonStyle(.marginalia(.quiet, .regular, in: colorScheme))`.
    static func marginalia(
        _ role: MarginaliaButtonRole,
        _ size: MarginaliaButtonSize,
        in scheme: ColorScheme
    ) -> MarginaliaButtonStyle {
        MarginaliaButtonStyle(role: role, size: size, scheme: scheme)
    }
}
