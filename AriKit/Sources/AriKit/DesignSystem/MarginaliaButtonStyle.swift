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

    /// Filled roles (`.primary`, `.recording`) render as accent/red-tinted Liquid Glass
    /// (`docs/plans/liquid-glass-adoption.md` — chrome/action layer only). `.secondary`/`.quiet`
    /// stay flat tonal/text surfaces — they're not the Signal.
    public var rendersAsGlass: Bool {
        switch self {
        case .primary, .recording: true
        case .secondary, .quiet: false
        }
    }
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
            MarginaliaButtonSpec(fill: .recordingRed, label: .canvas, stroke: nil, pressed: .recordingRedPressed)
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
        let shape = RoundedRectangle(cornerRadius: MarginaliaRadius.control.value, style: .continuous)

        let label = configuration.label
            .marginaliaTextStyle(.body, in: scheme, ink: spec.label)
            .frame(height: size.controlHeight)
            .padding(.horizontal, MarginaliaSpacing.md.value)

        if role.rendersAsGlass {
            // Filled roles (primary/recording) → accent/recording-red-tinted Liquid Glass, the
            // chrome/action-layer Signal (`docs/plans/liquid-glass-adoption.md`). `.interactive()`
            // supplies its own press response, so no manual pressed-fill branch applies here.
            // Glass controls take the SYSTEM's capsule curvature (macOS 26 controls are round,
            // concentric with window corners — liquid-glass-adoption.md v2); flat Marginalia
            // surfaces below keep the brand 6pt control radius.
            label
                .glassEffect(.regular.tint(Color.marginalia(spec.fill!, in: scheme)).interactive(), in: Capsule())
        } else {
            label
                .background {
                    shape.fill(fillColor(spec: spec, isPressed: isPressed))
                }
                .overlay {
                    if let stroke = spec.stroke {
                        shape.strokeBorder(Color.marginalia(stroke, in: scheme), lineWidth: 1)
                    }
                }
                // `.quiet` has no fill (and a `.clear` fill isn't hit-tested), so without an
                // explicit content shape only the label's own pixels are clickable — the
                // control's padding would be dead space.
                .contentShape(shape)
        }
    }

    /// Pressed-fill resolution for the non-glass roles only (`.secondary`/`.quiet`) — the glass
    /// roles get their press response from `.interactive()` and never call this.
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
