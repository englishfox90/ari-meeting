//
//  NotchOverlayStyle.swift — replaces ari-notch/Sources/AriNotch/NotchStyle.swift, re-themed
//  onto Marginalia (docs/plans/notch-panel-absorption.md §5, §10 step 2).
//
//  Shared visual language for the island content views (the recording HUD + the upcoming
//  alert). `NotchPalette` and every hex literal from the sidecar die here — every role below
//  resolves a Marginalia dark-palette token (`MarginaliaColorRole`), always against `.dark`
//  (the island is forced dark by `IslandContainerView`; these styles are constructed with the
//  ambient `.dark` scheme rather than re-deriving it).
//
//  DESIGN — Signal Rule still governs, re-expressed in Marginalia roles (plan §5 table):
//    • `.recordingRed` lands ONLY on the REC dot (while actively recording) and the Stop button.
//    • `.accent` lands ONLY on the upcoming alert's primary Record action.
//  Everything else — glass buttons, the audio meter, the open-app affordance, all labels — is
//  `.inkBody`/`.inkSecondary`, NEVER an accent color. No-Fake-State: the meter visualizes the
//  REAL `audioLevel` and collapses to a flat floor at silence; it never animates fabricated
//  motion.
//
import AriKit
import SwiftUI

// MARK: - Button styles (glass secondary, accent/recording primary, circular icon)

/// Translucent glass capsule for SECONDARY controls (Dismiss). `.ultraThinMaterial` over the
/// near-black island reads as a soft dark glass pill — the Dynamic-Island / Control-Center look.
/// Never the accent/recording-red signal colors.
struct NotchGlassCapsuleButtonStyle: ButtonStyle {
    var scheme: ColorScheme = .dark
    var disabledLook: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(Color.marginalia(.inkBody, in: scheme).opacity(disabledLook ? 0.5 : 1.0))
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

/// Accent capsule for the upcoming alert's single PRIMARY (non-capture) action — Record. The
/// Signal-Rule accent surface for that view (plan §5 table: old amber -> `.accent`).
struct NotchAccentCapsuleButtonStyle: ButtonStyle {
    var scheme: ColorScheme = .dark

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.semibold)
            // `.canvas` label for AA contrast on the accent fill in both schemes (matches the
            // `MenuBarRow` `.accent` reasoning).
            .foregroundStyle(Color.marginalia(.canvas, in: scheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(Color.marginalia(.accent, in: scheme))
            )
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Recording-red capsule for the HUD's single PRIMARY (capture) action — Stop. `dimmed` shows
/// the honest `.stopping` phase ("Stopping...") without changing the layout — plan §2: this
/// REPLACES the sidecar's local `stopConfirming` flag with the real phase.
struct NotchRecordingCapsuleButtonStyle: ButtonStyle {
    var scheme: ColorScheme = .dark
    var dimmed: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.marginalia(.canvas, in: scheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.marginalia(.recordingRed, in: scheme).opacity(dimmed ? 0.6 : 1.0))
            )
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Small circular glass icon button (open-app affordance, hover-revealed). Never an accent
/// color — it is a utility control, not the signal.
struct CircleIconButtonStyle: ButtonStyle {
    var scheme: ColorScheme = .dark

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.marginalia(.inkBody, in: scheme))
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

/// A stylized waveform strip that visualizes the REAL instantaneous `audioLevel` (0...1). Each
/// bar's height is a fixed silhouette fraction scaled by the live level, so the strip swells
/// with louder input and collapses to a flat floor at silence — an honest meter, never
/// fabricated motion (No-Fake-State). `.inkSecondary` fill only; never an accent color.
struct AudioMeterView: View {
    /// Latest instantaneous level, 0...1 (clamped).
    var level: Double
    var scheme: ColorScheme = .dark

    /// Fixed waveform silhouette (0...1 per bar). Deterministic — the strip's SHAPE is constant;
    /// only its amplitude tracks the live level.
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
                    .fill(Color.marginalia(.inkSecondary, in: scheme))
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
