//
//  IslandPanelController.swift
//  ari-notch
//
//  WS-H — the AppKit host for the custom simulated Dynamic Island. Owns ONE
//  borderless NSPanel hosting `IslandContainerView` (which wraps the reused
//  `NotchRootView`), and keeps it anchored TOP-CENTER of the currently ACTIVE
//  screen. Replaces the dropped DynamicNotchKit `DynamicNotch { }.expand()`.
//
//  Design of the panel (the crux — see inline comments for each choice):
//    • borderless + nonactivating so it overlays without stealing focus;
//    • clear/transparent so only the black island shape is visible;
//    • floats above the menu bar so it can cover the notch area;
//    • shows on every Space and over fullscreen apps;
//    • takes clicks (buttons work) WITHOUT activating (never `makeKey`).
//
//  Screen anchoring: the island is PINNED to the PRIMARY display — the one
//  designated "main" in System Settings ▸ Displays (always the screen whose
//  global frame origin is (0,0)). It deliberately does NOT follow the active
//  window from screen to screen; a meeting HUD that teleports when you click
//  another monitor reads as a bug. We re-anchor only when the display layout
//  itself changes (e.g. the user reassigns the main display), and continuously
//  as the SwiftUI island resizes (collapsed↔expanded).
//

import AppKit
import SwiftUI

/// Borderless panel that REFUSES macOS's automatic frame-constraining.
///
/// By default `NSWindow.setFrame` runs the requested rect through
/// `constrainFrameRect(_:to:)`, which clamps a window so it stays within the
/// screen's *visible* frame — i.e. BELOW the menu bar. That is exactly what left
/// the island floating a menu-bar-height gap under the top edge even though we
/// asked for `screen.frame.maxY`. Returning the rect unchanged disables the
/// clamp so the island can sit flush against the physical top edge and fuse with
/// the notch. (This is the lightweight alternative to the private-API CGSSpace
/// that boring.notch/Atoll use; CGSSpace is only additionally needed to also
/// cover fullscreen apps, which we don't require.)
final class TopEdgePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class IslandPanelController {

    private let model: NotchModel
    private let emitter: any NotchActionEmitter
    private let environment = IslandEnvironment()

    private let panel: TopEdgePanel
    private let hostingView: NSHostingView<IslandContainerView>

    /// Last size the SwiftUI island reported; used to re-anchor on screen /
    /// active-app changes without waiting for a new layout pass.
    private var currentContentSize: CGSize = .init(width: 190, height: 30)

    private var observers: [NSObjectProtocol] = []

    init(model: NotchModel, emitter: any NotchActionEmitter) {
        self.model = model
        self.emitter = emitter

        // MARK: Panel construction
        //
        // styleMask:
        //   .borderless        — no title bar / frame; we draw the whole surface.
        //   .nonactivatingPanel — the panel can receive mouse clicks (so the
        //                         Pause/Stop/Record buttons work) WITHOUT becoming
        //                         key or activating the app. That is exactly why we
        //                         show with `orderFrontRegardless()` and NEVER call
        //                         `makeKey*`: a nonactivating panel routes clicks to
        //                         its controls while the user's frontmost app keeps
        //                         focus. (An ordinary window would need to become key
        //                         to click, stealing focus from the meeting app.)
        panel = TopEdgePanel(
            contentRect: NSRect(x: 0, y: 0, width: 190, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Transparent surface: only the black island shape shows; the rest of the
        // panel rect is see-through (and, being nonactivating, still clickable only
        // where the SwiftUI content is hit-testable).
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow: the physical notch casts none, so a shadow would draw a rim
        // around the island and break the "part of the hardware" illusion. Flat,
        // borderless, pure-black — like the iPhone notch / Dynamic Island.
        panel.hasShadow = false

        // Level: sit ABOVE the menu bar so the island can overlay the notch area.
        // `.mainMenu + 3` is the value the proven notch apps (boring.notch / Atoll)
        // use — comfortably above the menu-bar layer (`.mainMenu` == 24) so the
        // island reliably draws over the menu bar / notch strip on notched Macs.
        panel.level = NSWindow.Level.mainMenu + 3

        // Show on every Space, float over fullscreen apps, don't move with the
        // active window, and never appear in Cmd-` window cycling.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        // Buttons must click — do NOT ignore mouse events.
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Belt-and-suspenders: never let AppKit try to make this the key/main
        // window (reinforces the nonactivating click behavior).
        panel.isMovableByWindowBackground = false

        // MARK: SwiftUI host
        //
        // Built after `panel` exists so `onResize` can drive `panel` sizing. We
        // stash a placeholder root first, then assign the real one below (the
        // closure captures `self`, so it must come after `super`-free init fields
        // are set — this is a final class with no super, so we assign post-hoc).
        hostingView = NSHostingView(
            rootView: IslandContainerView(
                model: model,
                environment: environment,
                emitter: emitter,
                onResize: { _ in },
                onPresentationChange: { _ in }
            )
        )
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        // CRITICAL for the integrated-notch look: an NSHostingView insets its
        // content by the window's safe area. Because this panel overlaps the
        // menu-bar / notch strip, that inset would push the island DOWN by the
        // notch height, so the black shape floats in a gap below the physical top
        // edge instead of fusing with it. Clearing `safeAreaRegions` lets the
        // island's square top sit flush against the very top edge (macOS 13.3+;
        // our floor is macOS 14).
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView

        // Now wire the real callbacks (capture self).
        hostingView.rootView = IslandContainerView(
            model: model,
            environment: environment,
            emitter: emitter,
            onResize: { [weak self] size in
                self?.islandDidResize(to: size)
            },
            onPresentationChange: { [weak self] presentation in
                self?.applyPresentation(presentation)
            }
        )
    }

    // MARK: - Show / lifecycle

    /// Start following the active screen and reflect the CURRENT model state.
    /// The island is transient: the panel is NOT ordered front here — it starts
    /// hidden and is shown only when presentation becomes `.expanded` (recording
    /// or an upcoming alert). `applyPresentation` orders it in/out as the model
    /// changes; the same value is also pushed reactively from the SwiftUI
    /// container's `onPresentationChange`.
    func show() {
        installObservers()
        // Drive the initial state explicitly (idle → hidden) so we don't depend
        // on SwiftUI `onAppear` timing before the panel is ever ordered in.
        applyPresentation(
            IslandPresentation.derive(
                isRecording: model.isRecording,
                hasUpcoming: model.upcomingMeeting != nil
            )
        )
    }

    /// Show or hide the panel based on presentation. `.hidden` → `orderOut`
    /// (island disappears entirely, e.g. after Stop). `.expanded` / `.collapsed`
    /// → re-anchor top-center of the active screen and `orderFrontRegardless()`
    /// (never `makeKey*`, so the user's frontmost app keeps focus).
    private func applyPresentation(_ presentation: IslandPresentation) {
        switch presentation {
        case .hidden:
            panel.orderOut(nil)
        case .expanded, .collapsed:
            refreshNotchEnvironment()
            reanchor()
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Primary-screen anchoring

    /// The display designated "main" in System Settings ▸ Displays. In the global
    /// coordinate space that display's frame origin is always (0,0), which is the
    /// stable, active-window-independent way to identify it. Falls back to
    /// `NSScreen.main` then the first screen if (pathologically) none is at the
    /// origin.
    private var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func installObservers() {
        let nc = NotificationCenter.default

        // Screen layout changed (display added/removed, resolution/arrangement,
        // notch geometry, OR the user reassigning the main display): re-derive the
        // notch environment and re-anchor onto the (possibly new) primary display.
        // We intentionally do NOT observe app-activation — the island stays put on
        // the primary display rather than following the frontmost window.
        observers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenChange() }
        })
    }

    private func handleScreenChange() {
        refreshNotchEnvironment()
        reanchor()
    }

    /// Called by the SwiftUI island whenever its rendered size changes (the
    /// collapsed↔expanded morph). We resize + re-anchor the panel to follow so
    /// the click region stays tight to the visible island.
    private func islandDidResize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // Ignore sub-pixel churn.
        if abs(size.width - currentContentSize.width) < 0.5,
           abs(size.height - currentContentSize.height) < 0.5 {
            return
        }
        currentContentSize = size
        reanchor()
    }

    /// Re-position (and size) the panel top-center of the PRIMARY screen using the
    /// last known content size. We use its full `.frame` (NOT `.visibleFrame`) so
    /// the island hugs the very top edge, over the menu bar.
    private func reanchor() {
        guard let screen = primaryScreen else { return }
        let frame = IslandGeometry.islandFrame(
            inScreen: screen.frame,
            contentSize: currentContentSize
        )
        panel.setFrame(frame, display: true)
    }

    /// Read the PRIMARY screen's physical notch (if any) into the chrome
    /// environment so the collapsed pill can merge with it. AppKit reads live
    /// here; the pure arithmetic is `IslandGeometry.notchWidth` (unit-tested).
    private func refreshNotchEnvironment() {
        guard let screen = primaryScreen else {
            environment.notchSize = nil
            return
        }

        let notchHeight = screen.safeAreaInsets.top
        guard notchHeight > 0 else {
            // No top inset → no notch on this screen.
            environment.notchSize = nil
            return
        }

        // Width from the two auxiliary top areas flanking the notch (macOS 12+).
        let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightW = screen.auxiliaryTopRightArea?.width ?? 0
        if let width = IslandGeometry.notchWidth(
            screenWidth: screen.frame.width,
            leftAuxWidth: leftW,
            rightAuxWidth: rightW
        ) {
            environment.notchSize = CGSize(width: width, height: notchHeight)
        } else {
            // Inset present but aux areas unavailable: fall back to just the
            // height so the island still hugs the top; width comes from content.
            environment.notchSize = nil
        }
    }

    deinit {
        // Observers are removed on teardown. `deinit` isn't main-actor isolated,
        // but NotificationCenter removal is thread-safe.
        let nc = NotificationCenter.default
        for token in observers {
            nc.removeObserver(token)
        }
    }
}
