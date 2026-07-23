//
//  IslandGeometry.swift — ported from ari-notch/Sources/AriNotch/IslandGeometry.swift
//  (docs/plans/notch-panel-absorption.md §2, §10 step 1).
//
//  PURE geometry + presentation math for the custom simulated Dynamic Island. Deliberately
//  AppKit-free (CoreGraphics only) so every rule here is unit-testable without a display or a run
//  loop. The AppKit host (`NotchPanelController`, app target) reads live `NSScreen` values and
//  feeds the raw numbers into these functions; the SwiftUI chrome (`IslandContainerView`, app
//  target) consumes `IslandPresentation`.
//
//  Nothing here imports AppKit/SwiftUI on purpose — see NotchGeometryTests.
//
import CoreGraphics

// MARK: - Presentation state

/// The visual states of the island, derived from the app's own `RecordingSession.Phase` (the
/// sidecar's wire-model booleans die with the port — see `derive(phase:hasUpcoming:)`).
///
/// The island is a TRANSIENT surface — it is NOT always present. It appears only while recording
/// (or stopping) or when an upcoming-meeting alert is active, and orders OUT (fully off-screen)
/// when idle so a stopped session leaves nothing stuck open.
///
/// - `hidden`    — not recording/stopping and no upcoming meeting. The host orders the panel OUT
///                 entirely (no pill, no chrome).
/// - `collapsed` — reserved / currently UNUSED. `derive` never returns it. Kept so the chrome can
///                 special-case a minimal always-present pill in the future without a signature
///                 change; the container still renders it.
/// - `expanded`  — recording, stopping, OR an upcoming meeting exists: the panel is shown and
///                 grows to host the HUD or the prompt-to-record alert.
public enum IslandPresentation: Equatable, Sendable {
    case hidden
    case collapsed
    case expanded

    /// Pure mapping from the app's real phase + upcoming signal. `.recording`/`.stopping` always
    /// expand (the honest "Stopping…" HUD, not a hidden panel mid-drain). Every other phase stays
    /// `.hidden` UNLESS an upcoming meeting is present — `.starting`/`.consentPrompt` deliberately
    /// stay hidden too (plan §4): the app/menu bar already show "Starting…", so the island appears
    /// only once capture is actually live.
    public static func derive(phase: RecordingSession.Phase, hasUpcoming: Bool) -> IslandPresentation {
        switch phase {
        case .recording, .stopping:
            return .expanded
        case .idle, .consentPrompt, .starting, .saved, .failed:
            return hasUpcoming ? .expanded : .hidden
        }
    }
}

// MARK: - Frame math

public enum IslandGeometry {
    /// Extra width the EXPANDED island keeps past the physical notch on EACH side. A bare
    /// notch-width island reads as cramped once real content (REC dot, timer, meter, Stop
    /// button) has to squeeze into it — this floor makes the expanded island visibly wider than
    /// the notch it grows from, on both sides, while staying centered on it. Purely a floor:
    /// content that already needs more room than `notchWidth + 2 * expandedOverhang` still wins
    /// (`expandedMinWidth` / SwiftUI's own `.frame(minWidth:)` never shrinks content).
    public static let expandedOverhang: CGFloat = 28

    /// The expanded island's width floor: the active screen's physical notch width plus
    /// `expandedOverhang` on each side, or `nil` on a non-notched screen (nothing to hug/overhang
    /// past — the collapsed pill already falls back to a plain centered pill there, and the
    /// expanded island is sized by its content alone).
    public static func expandedMinWidth(notchWidth: CGFloat?) -> CGFloat? {
        guard let notchWidth, notchWidth > 1 else { return nil }
        return notchWidth + 2 * expandedOverhang
    }

    /// Frame for the island panel: centered horizontally on `screenFrame`, its TOP edge flush to
    /// the screen's top (`screenFrame.maxY`) so it hugs the very top edge over the menu bar /
    /// notch.
    ///
    /// Uses the passed `screenFrame` directly, so multi-monitor math is correct: a screen whose
    /// origin is offset (e.g. `x = 1512`) centers on THAT screen, not the global (0,0) origin.
    /// Caller passes `screen.frame` (NOT `visibleFrame`) precisely so the island can sit above the
    /// menu bar.
    public static func islandFrame(inScreen screenFrame: CGRect, contentSize: CGSize) -> CGRect {
        let x = screenFrame.midX - contentSize.width / 2.0
        let y = screenFrame.maxY - contentSize.height
        return CGRect(x: x, y: y, width: contentSize.width, height: contentSize.height)
    }

    /// Physical-notch width derived from a screen's full width minus the two auxiliary top areas
    /// that flank the notch (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`). Returns
    /// `nil` when there is effectively no notch (the arithmetic collapses to ~0). The AppKit reads
    /// live in the controller; only this arithmetic is tested.
    public static func notchWidth(
        screenWidth: CGFloat,
        leftAuxWidth: CGFloat,
        rightAuxWidth: CGFloat
    ) -> CGFloat? {
        let width = screenWidth - leftAuxWidth - rightAuxWidth
        // Guard against float noise and non-notched screens (aux areas span the whole width,
        // leaving ~0).
        return width > 1.0 ? width : nil
    }
}
