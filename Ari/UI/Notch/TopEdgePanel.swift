//
//  TopEdgePanel.swift — ported from ari-notch/Sources/AriNotch/IslandPanelController.swift
//  (docs/plans/notch-panel-absorption.md §2, §10 step 3).
//
//  Borderless panel that REFUSES macOS's automatic frame-constraining.
//
//  By default `NSWindow.setFrame` runs the requested rect through `constrainFrameRect(_:to:)`,
//  which clamps a window so it stays within the screen's *visible* frame — i.e. BELOW the menu
//  bar. That is exactly what would leave the island floating a menu-bar-height gap under the
//  top edge even though we ask for `screen.frame.maxY`. Returning the rect unchanged disables
//  the clamp so the island can sit flush against the physical top edge and fuse with the notch.
//
import AppKit

final class TopEdgePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
