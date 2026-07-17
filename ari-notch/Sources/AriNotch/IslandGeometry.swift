//
//  IslandGeometry.swift
//  ari-notch
//
//  PURE geometry + presentation math for the custom simulated Dynamic Island
//  (WS-H). Deliberately AppKit-free (CoreGraphics only) so every rule here is
//  unit-testable without a display or a run loop. The AppKit host
//  (`IslandPanelController`) reads live `NSScreen` values and feeds the raw
//  numbers into these functions; the SwiftUI chrome (`IslandContainerView`)
//  consumes `IslandPresentation`.
//
//  Nothing here imports AppKit/SwiftUI on purpose — see IslandGeometryTests.
//

import CoreGraphics

// MARK: - Presentation state

/// The visual states of the island, derived purely from the model.
///
/// The island is a TRANSIENT surface — it is NOT always present. It appears only
/// while recording or when an upcoming-meeting alert is active, and orders OUT
/// (fully off-screen) when idle so a stopped session leaves nothing stuck open.
///
/// - `hidden`   — idle: not recording and no upcoming meeting. The host orders
///                the panel OUT entirely (no pill, no chrome).
/// - `collapsed`— reserved / currently UNUSED. `derive` never returns it. Kept
///                so the chrome can special-case a minimal always-present pill in
///                the future without a wire change; the container still renders it.
/// - `expanded` — recording OR an upcoming meeting exists: the panel is shown and
///                grows to host `NotchRootView` (the HUD or the prompt-to-record
///                alert).
enum IslandPresentation: Equatable {
    case hidden
    case collapsed
    case expanded

    /// Pure mapping from the two model signals the island cares about.
    /// Idle → `.hidden` (never `.collapsed`): the island is transient and must
    /// disappear after Stop. It is shown ONLY while recording or upcoming.
    static func derive(isRecording: Bool, hasUpcoming: Bool) -> IslandPresentation {
        if isRecording || hasUpcoming { return .expanded }
        return .hidden
    }
}

// MARK: - Frame math

enum IslandGeometry {

    /// Frame for the island panel: centered horizontally on `screenFrame`, its
    /// TOP edge flush to the screen's top (`screenFrame.maxY`) so it hugs the
    /// very top edge over the menu bar / notch.
    ///
    /// Uses the passed `screenFrame` directly, so multi-monitor math is correct:
    /// a screen whose origin is offset (e.g. `x = 1512`) centers on THAT screen,
    /// not the global (0,0) origin. Caller passes `screen.frame` (NOT
    /// `visibleFrame`) precisely so the island can sit above the menu bar.
    static func islandFrame(inScreen screenFrame: CGRect, contentSize: CGSize) -> CGRect {
        let x = screenFrame.midX - contentSize.width / 2.0
        let y = screenFrame.maxY - contentSize.height
        return CGRect(x: x, y: y, width: contentSize.width, height: contentSize.height)
    }

    /// Physical-notch width derived from a screen's full width minus the two
    /// auxiliary top areas that flank the notch (`NSScreen.auxiliaryTopLeftArea`
    /// / `auxiliaryTopRightArea`). Returns `nil` when there is effectively no
    /// notch (the arithmetic collapses to ~0). The AppKit reads live in the
    /// controller; only this arithmetic is tested.
    static func notchWidth(
        screenWidth: CGFloat,
        leftAuxWidth: CGFloat,
        rightAuxWidth: CGFloat
    ) -> CGFloat? {
        let width = screenWidth - leftAuxWidth - rightAuxWidth
        // Guard against float noise and non-notched screens (aux areas span the
        // whole width, leaving ~0).
        return width > 1.0 ? width : nil
    }
}
