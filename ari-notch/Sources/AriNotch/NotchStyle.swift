//
//  NotchStyle.swift
//  ari-notch
//
//  Shared visual language for the island content views (WS-C HUD + WS-G upcoming
//  alert). Consolidates the three Arivo brand tokens (previously duplicated
//  privately in each view) into ONE Swift source of truth, plus the reusable
//  "Apple-esque" control chrome: translucent glass capsules / circular icon
//  buttons that press with a spring, and a live multi-bar audio meter.
//
//  DESIGN — Signal Rule still governs: Arivo Amber (`NotchPalette.amber`) lands
//  ONLY on the one thing that matters (the REC dot while actively recording and
//  the single primary action — Stop / Record). Everything else — glass buttons,
//  the audio meter, the open-app affordance, all labels — is warm ink / muted
//  ink, NEVER amber. No-Fake-State: the meter visualizes the REAL `audioLevel`
//  and collapses to a flat floor at silence; it never animates fabricated motion.
//
//  These tokens are invisible to the web visual-system test — keep them in sync
//  with `DESIGN.json` (see the drift table in README.md).
//

import SwiftUI

// MARK: - Brand palette (single Swift source of truth)

enum NotchPalette {
    /// Arivo Amber — the Signal-Rule accent. REC dot (active) + primary action ONLY.
    static let amber = Color(hex: 0xE8A020)
    /// Warm cream primary ink (timer, titles, control labels).
    static let ink = Color(hex: 0xF5EFE6)
    /// Warm taupe muted ink (eyebrows, secondary text, meter fill, glass labels).
    static let mutedInk = Color(hex: 0xA89F90)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

// MARK: - Button styles (glass secondary, amber primary, circular icon)

/// Translucent glass capsule for SECONDARY controls (Pause/Resume, Dismiss).
/// `.ultraThinMaterial` over the near-black island reads as a soft dark glass
/// pill — the Dynamic-Island / Control-Center look. Never amber.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var disabledLook: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(NotchPalette.ink.opacity(disabledLook ? 0.5 : 1.0))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
            )
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Amber capsule for the single PRIMARY action (Stop / Record) — the Signal-Rule
/// accent surface. Black label for AA contrast on amber. `dimmed` shows the brief
/// pending state (e.g. "Stopping…") without changing the layout.
struct AccentCapsuleButtonStyle: ButtonStyle {
    var dimmed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(NotchPalette.amber.opacity(dimmed ? 0.6 : 1.0))
            )
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Small circular glass icon button (open-app affordance, hover-revealed). Never
/// amber — it is a utility control, not the signal.
struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(NotchPalette.ink)
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            )
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Live audio meter

/// A stylized waveform strip that visualizes the REAL instantaneous `audioLevel`
/// (0…1). Each bar's height is a fixed silhouette fraction scaled by the live
/// level, so the strip swells with louder input and collapses to a flat floor at
/// silence — an honest meter, never fabricated motion (No-Fake-State). Muted-ink
/// fill only; never the amber accent.
struct AudioMeterView: View {
    /// Latest instantaneous level, 0…1 (clamped).
    var level: Double

    /// Fixed waveform silhouette (0…1 per bar). Deterministic — the strip's
    /// SHAPE is constant; only its amplitude tracks the live level.
    private let silhouette: [CGFloat] = [
        0.30, 0.55, 0.42, 0.72, 0.50, 0.88, 0.62, 1.00, 0.70, 0.92,
        0.66, 1.00, 0.56, 0.82, 0.46, 0.74, 0.52, 0.64, 0.38, 0.48
    ]

    private let barWidth: CGFloat = 2.5
    private let spacing: CGFloat = 3
    private let floorHeight: CGFloat = 2.5
    private let maxHeight: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(silhouette.indices, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(NotchPalette.mutedInk)
                    .frame(width: barWidth, height: barHeight(silhouette[i]))
            }
        }
        .frame(height: maxHeight)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: clampedLevel)
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int(clampedLevel * 100)) percent")
    }

    private var clampedLevel: CGFloat {
        CGFloat(min(1.0, max(0.0, level)))
    }

    private func barHeight(_ fraction: CGFloat) -> CGFloat {
        floorHeight + (maxHeight - floorHeight) * fraction * clampedLevel
    }
}
