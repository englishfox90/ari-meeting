//
//  NotchGeometryTests.swift — ported from ari-notch/Tests/AriNotchTests/IslandGeometryTests.swift
//  (docs/plans/notch-panel-absorption.md §7 suite 1).
//
//  Unit tests for the PURE island geometry + presentation math (`IslandGeometry`,
//  `IslandPresentation`). No AppKit / no display — these cover exactly the code the human's
//  visual pass can't: centering math (including multi-monitor origin offsets), top-edge
//  flushness, notch-width derivation, and the basic recording/idle state mapping (the exhaustive
//  per-`Phase` mapping lives in `NotchPresentationTests`).
//
import CoreGraphics
import Testing
@testable import AriViewModels

@Suite("NotchGeometry")
struct NotchGeometryTests {
    // MARK: - islandFrame: centering + top-flush

    @Test("islandFrame centers on the primary screen; content's own top hugs the screen top")
    func islandFrameCentersOnPrimaryScreen() {
        // 1512×982 built-in display at origin (0,0).
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let content = CGSize(width: 200, height: 32)

        let frame = IslandGeometry.islandFrame(inScreen: screen, contentSize: content)

        // Horizontally centered: midX 756 → x = 756 - 100 = 656.
        #expect(abs(frame.origin.x - 656) < 0.001)
        // Bottom (where content ends) is unaffected by the bleed: y = 982 - 32 = 950.
        #expect(abs(frame.origin.y - 950) < 0.001)
        #expect(abs(frame.width - 200) < 0.001)
        // The panel is `topBleed` taller than the content it reports.
        #expect(abs(frame.height - (32 + IslandGeometry.topBleed)) < 0.001)
        // The panel's OWN top edge extends `topBleed` past the screen top (safety margin) — the
        // visible island's top (maxY - topBleed, painted flush by the SwiftUI chrome) is what
        // actually hugs the screen edge; see `IslandContainerView`.
        #expect(abs(frame.maxY - (screen.maxY + IslandGeometry.topBleed)) < 0.001)
    }

    @Test("islandFrame centers on an offset secondary screen, not the global origin")
    func islandFrameCentersOnOffsetSecondaryScreen() {
        // External monitor to the RIGHT of the laptop: origin x = 1512. Proves the math centers
        // on THAT screen, not the global (0,0) origin.
        let screen = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let content = CGSize(width: 380, height: 180)

        let frame = IslandGeometry.islandFrame(inScreen: screen, contentSize: content)

        // midX = 1512 + 1280 = 2792 → x = 2792 - 190 = 2602.
        #expect(abs(frame.origin.x - 2602) < 0.001)
        #expect(abs(frame.origin.y - (1440 - 180)) < 0.001)
        // Center of the island == center of the screen, horizontally.
        #expect(abs(frame.midX - screen.midX) < 0.001)
        #expect(abs(frame.maxY - (screen.maxY + IslandGeometry.topBleed)) < 0.001)
    }

    @Test("islandFrame handles a negative-origin screen")
    func islandFrameHandlesNegativeOriginScreen() {
        // Monitor to the LEFT / above: negative origin.
        let screen = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        let content = CGSize(width: 300, height: 40)

        let frame = IslandGeometry.islandFrame(inScreen: screen, contentSize: content)

        #expect(abs(frame.midX - screen.midX) < 0.001)
        #expect(abs(frame.maxY - (screen.maxY + IslandGeometry.topBleed)) < 0.001)
    }

    @Test("islandFrame's bottom edge (where content ends) is bleed-independent")
    func islandFrameBottomUnaffectedByBleed() {
        // The bottom anchor (content's own end) must be identical to the pre-bleed formula
        // (`screenFrame.maxY - contentSize.height`) — only the top grows. This is what keeps the
        // island's visible position on screen unchanged from before the bleed fix.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let content = CGSize(width: 200, height: 32)

        let frame = IslandGeometry.islandFrame(inScreen: screen, contentSize: content)

        #expect(abs(frame.origin.y - (screen.maxY - content.height)) < 0.001)
    }

    // MARK: - notchWidth

    @Test("notchWidth resolves the physical-notch width from the flanking aux areas")
    func notchWidthPresent() {
        // 1512-wide screen, ~180pt notch: aux areas 666 + 666 flank it.
        let width = IslandGeometry.notchWidth(screenWidth: 1512, leftAuxWidth: 666, rightAuxWidth: 666)
        let unwrapped = try! #require(width)
        #expect(abs(unwrapped - 180) < 0.001)
    }

    @Test("notchWidth is nil when the aux areas span the whole width (no notch)")
    func notchWidthAbsentWhenAuxSpansWholeWidth() {
        // Non-notched external monitor: aux areas span full width, leaving ~0 → nil.
        let width = IslandGeometry.notchWidth(screenWidth: 2560, leftAuxWidth: 1280, rightAuxWidth: 1280)
        #expect(width == nil)
    }

    @Test("notchWidth is nil when there is no aux info at all")
    func notchWidthAbsentWhenZeroAux() {
        // No aux info at all collapses to full width, which is NOT a notch.
        let width = IslandGeometry.notchWidth(screenWidth: 1440, leftAuxWidth: 720, rightAuxWidth: 720)
        #expect(width == nil)
    }

    // MARK: - expandedMinWidth

    @Test("expandedMinWidth floors at notch width plus overhang on each side")
    func expandedMinWidthAddsOverhangOnNotchedScreen() {
        let width = IslandGeometry.expandedMinWidth(notchWidth: 180)
        let unwrapped = try! #require(width)
        #expect(abs(unwrapped - (180 + 2 * IslandGeometry.expandedOverhang)) < 0.001)
        // Visibly wider than the bare notch on both sides.
        #expect(unwrapped > 180)
    }

    @Test("expandedMinWidth is nil on a non-notched screen — content alone drives width")
    func expandedMinWidthNilWhenNoNotch() {
        #expect(IslandGeometry.expandedMinWidth(notchWidth: nil) == nil)
    }

    @Test("expandedMinWidth is nil for a ~zero notch width (float noise floor)")
    func expandedMinWidthNilForNearZeroNotch() {
        #expect(IslandGeometry.expandedMinWidth(notchWidth: 0.5) == nil)
    }

    // MARK: - fixedPanelFrame (structural fix: the panel never resizes mid-animation)

    @Test("fixedPanelFrame centers at maxPanelWidth on a screen wider than the ceiling")
    func fixedPanelFrameCentersAtMaxWidthOnWideScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let frame = IslandGeometry.fixedPanelFrame(inScreen: screen)

        #expect(abs(frame.width - IslandGeometry.maxPanelWidth) < 0.001)
        #expect(abs(frame.midX - screen.midX) < 0.001)
        #expect(abs(frame.height - (IslandGeometry.maxPanelContentHeight + IslandGeometry.topBleed)) < 0.001)
        // Same top anchor as the old per-resize `islandFrame`: topBleed above the screen's top.
        #expect(abs(frame.maxY - (screen.maxY + IslandGeometry.topBleed)) < 0.001)
    }

    @Test("fixedPanelFrame clamps width to a screen narrower than maxPanelWidth")
    func fixedPanelFrameClampsWidthOnNarrowScreen() {
        let narrowWidth: CGFloat = 400
        let screen = CGRect(x: 0, y: 0, width: narrowWidth, height: 900)

        let frame = IslandGeometry.fixedPanelFrame(inScreen: screen)

        #expect(abs(frame.width - narrowWidth) < 0.001)
        #expect(abs(frame.midX - screen.midX) < 0.001)
    }

    @Test("fixedPanelFrame centers on an offset secondary screen, not the global origin")
    func fixedPanelFrameCentersOnOffsetSecondaryScreen() {
        let screen = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

        let frame = IslandGeometry.fixedPanelFrame(inScreen: screen)

        #expect(abs(frame.midX - screen.midX) < 0.001)
        #expect(abs(frame.maxY - (screen.maxY + IslandGeometry.topBleed)) < 0.001)
    }

    @Test("fixedPanelFrame's frame depends only on screen params, not on any content size")
    func fixedPanelFrameIsContentIndependent() {
        // The whole point: calling this twice with the same screen always yields the same
        // frame — there is no content-size parameter to vary it, unlike `islandFrame`.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let first = IslandGeometry.fixedPanelFrame(inScreen: screen)
        let second = IslandGeometry.fixedPanelFrame(inScreen: screen)

        #expect(first == second)
    }

    // MARK: - IslandPresentation mapping (basic cases; exhaustive mapping in NotchPresentationTests)

    @Test("idle with no upcoming meeting is hidden — the island is transient")
    func presentationIdleIsHidden() {
        #expect(IslandPresentation.derive(phase: .idle, hasUpcoming: false) == .hidden)
    }

    @Test("recording is expanded")
    func presentationRecordingIsExpanded() {
        #expect(
            IslandPresentation.derive(phase: .recording(startedAt: .init()), hasUpcoming: false) == .expanded
        )
    }

    @Test("idle with an upcoming meeting is expanded")
    func presentationUpcomingIsExpanded() {
        #expect(IslandPresentation.derive(phase: .idle, hasUpcoming: true) == .expanded)
    }

    @Test("recording with an upcoming meeting is still expanded")
    func presentationRecordingAndUpcomingIsExpanded() {
        #expect(
            IslandPresentation.derive(phase: .recording(startedAt: .init()), hasUpcoming: true) == .expanded
        )
    }
}
