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

    /// Extra chrome height the AppKit panel keeps ABOVE the visible island's own top edge — an
    /// animation-timing safety margin (docs/plans/notch-panel-absorption.md, "top-gap during
    /// bounce" fix). Originally sized to absorb drift between the panel's discrete resize and the
    /// island's continuous spring; that discrete resize is gone now (`fixedPanelFrame` below —
    /// the panel no longer resizes mid-animation at all), but the bleed band stays as a second,
    /// independent margin: the SwiftUI chrome (`IslandContainerView`) still paints it solid black
    /// as part of the SAME `IslandShape` fill as the island body (one path, no layer seam), and
    /// `islandFrame`/`fixedPanelFrame` both still extend the panel `topBleed` points past the
    /// screen's physical top edge so even a stray fractional-pixel frame reveals more black
    /// chrome, never bare desktop, at the seam with the physical notch.
    public static let topBleed: CGFloat = 6

    /// The expanded island's width floor: the active screen's physical notch width plus
    /// `expandedOverhang` on each side, or `nil` on a non-notched screen (nothing to hug/overhang
    /// past — the collapsed pill already falls back to a plain centered pill there, and the
    /// expanded island is sized by its content alone).
    public static func expandedMinWidth(notchWidth: CGFloat?) -> CGFloat? {
        guard let notchWidth, notchWidth > 1 else { return nil }
        return notchWidth + 2 * expandedOverhang
    }

    /// Frame for the island panel: centered horizontally on `screenFrame`. The visible island's
    /// own top edge sits flush to the screen's top (`screenFrame.maxY`), exactly as before — but
    /// the PANEL's actual frame is `topBleed` points taller, extending that far ABOVE
    /// `screenFrame.maxY` as an animation-timing safety margin (see `topBleed`). The panel's
    /// bottom edge (`y`, i.e. where content ends) is unaffected: `y = screenFrame.maxY -
    /// contentSize.height`, unchanged from the pre-bleed formula.
    ///
    /// Uses the passed `screenFrame` directly, so multi-monitor math is correct: a screen whose
    /// origin is offset (e.g. `x = 1512`) centers on THAT screen, not the global (0,0) origin.
    /// Caller passes `screen.frame` (NOT `visibleFrame`) precisely so the island can sit above the
    /// menu bar.
    public static func islandFrame(inScreen screenFrame: CGRect, contentSize: CGSize) -> CGRect {
        let x = screenFrame.midX - contentSize.width / 2.0
        let y = screenFrame.maxY - contentSize.height
        let height = contentSize.height + topBleed
        return CGRect(x: x, y: y, width: contentSize.width, height: height)
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

    // MARK: - Fixed panel frame (structural fix for the expand-animation top-gap artifact)

    /// The panel's maximum width, over any content the expanded island ever needs
    /// (`IslandContainerView`'s own `maxWidth: 460` ceiling on expanded content leaves headroom
    /// under this). The panel no longer sizes to the island's LIVE content — see
    /// `fixedPanelFrame` — so this is a one-time ceiling, not a per-frame measurement.
    public static let maxPanelWidth: CGFloat = 520

    /// The panel's maximum content height (excluding `topBleed`), over the recording HUD and the
    /// upcoming-meeting alert alike (REC/title row + meter + up to two transcript lines +
    /// controls, or title + countdown + controls, each with their own padding). Generous
    /// deliberately: unused headroom is fully transparent and click-through (see
    /// `ClickThroughHostingView` in the app target), so oversizing costs nothing visually or
    /// interactively.
    public static let maxPanelContentHeight: CGFloat = 240

    /// The panel's FIXED frame for a given screen — sized once to `maxPanelWidth` ×
    /// (`maxPanelContentHeight` + `topBleed`), top-centered, with the panel's own top edge
    /// `topBleed` points above `screenFrame.maxY` (the same anchor `islandFrame` used for its
    /// per-resize frame). Width clamps to the screen's own width on a laptop narrower than
    /// `maxPanelWidth`.
    ///
    /// This is the structural fix for the animation-time top-gap artifact (three earlier attempts
    /// — no-overshoot spring, single-fill bleed band, whole-pixel snapping — all left a class of
    /// bug open because the panel was still being RESIZED via `setFrame` mid-animation on every
    /// SwiftUI geometry report, racing AppKit's own re-layout against Core Animation's
    /// interpolation). The panel's frame now depends ONLY on screen parameters, never on the
    /// island's live content size — `NotchPanelController` calls this exclusively from
    /// `reanchor()`, itself invoked only on construction and on
    /// `didChangeScreenParametersNotification`, never per content resize. The SwiftUI island still
    /// morphs continuously inside this larger, static panel via its own top-aligned layout; only
    /// the interactive (hit-testable) region tracks the live size now, not the window frame.
    public static func fixedPanelFrame(inScreen screenFrame: CGRect) -> CGRect {
        let width = min(maxPanelWidth, screenFrame.width)
        let height = maxPanelContentHeight + topBleed
        let x = screenFrame.midX - width / 2.0
        let y = screenFrame.maxY - maxPanelContentHeight
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
