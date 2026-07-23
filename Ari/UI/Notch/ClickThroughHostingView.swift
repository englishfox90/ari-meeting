//
//  ClickThroughHostingView.swift — hit-test pass-through for the FIXED, oversized notch panel
//  (docs/plans/notch-panel-absorption.md, structural fix for the expand-animation top-gap
//  artifact; see `IslandGeometry.fixedPanelFrame`).
//
//  `NotchPanelController` now gives its `TopEdgePanel` a fixed frame sized for the island's
//  MAXIMUM content, so the panel's `setFrame` never races the SwiftUI expand/collapse spring.
//  That frame is bigger than the visible island for most of its life (it is sized to the ceiling,
//  not the live content), and it sits over the menu bar and whatever else is beneath it. Without
//  this, the panel's mostly-transparent margin would silently swallow every click in that region.
//
//  This view accepts a hit ONLY inside `activeRect` — the visible island's own live footprint, in
//  this view's own bounds coordinates — and returns `nil` (pass the click through to whatever is
//  underneath) everywhere else. `NotchPanelController.updateActiveRect()` recomputes `activeRect`
//  every time the SwiftUI island reports a new size (`onResize`), so Stop / Record / Dismiss /
//  open-app stay fully clickable through every collapsed <-> expanded morph — this view's own
//  frame never changes to follow them anymore.
//
import AppKit
import AriViewModels
import SwiftUI

final class ClickThroughHostingView: NSHostingView<IslandContainerView> {
    /// The current interactive footprint (the visible island, plus a few points of click slack —
    /// see `NotchPanelController.hitTestSlack`), expressed in THIS view's own bounds coordinate
    /// system. Empty by default so nothing is clickable before the first `onResize` report.
    var activeRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `hitTest(_:)` receives `point` in the coordinate system of the receiver's SUPERVIEW, not
        // its own — convert explicitly rather than assume the two happen to coincide.
        let localPoint = superview?.convert(point, to: self) ?? point
        guard activeRect.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }
}
