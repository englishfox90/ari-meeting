//
//  NotchPanelController.swift — WS-H, ported from
//  ari-notch/Sources/AriNotch/IslandPanelController.swift (docs/plans/notch-panel-absorption.md
//  §2, §3, §10 step 3).
//
//  The AppKit host for the custom simulated Dynamic Island. Owns ONE borderless `TopEdgePanel`
//  hosting `IslandContainerView`, and keeps it anchored TOP-CENTER of the currently ACTIVE
//  (primary) screen.
//
//  Design of the panel (the crux — see inline comments for each choice):
//    • borderless + nonactivating so it overlays without stealing focus;
//    • clear/transparent so only the black island shape is visible;
//    • floats above the menu bar so it can cover the notch area;
//    • shows on every Space and over fullscreen apps;
//    • takes clicks (buttons work) WITHOUT activating (never `makeKey`).
//
//  Screen anchoring: the island is PINNED to the PRIMARY display — the one designated "main" in
//  System Settings > Displays (always the screen whose global frame origin is (0,0)). It
//  deliberately does NOT follow the active window from screen to screen; a meeting HUD that
//  teleports when you click another monitor reads as a bug. We re-anchor (`reanchor()`, i.e.
//  `setFrame`) ONLY when the display layout itself changes — the panel is otherwise a FIXED size
//  (`IslandGeometry.fixedPanelFrame`, sized for the island's maximum content) so it never resizes
//  as the SwiftUI island itself morphs collapsed <-> expanded; only the click-through hit-test
//  region (`updateActiveRect()`) tracks that live size. This is the structural fix for the
//  expand-animation top-gap artifact (docs/plans/notch-panel-absorption.md): a discrete `setFrame`
//  racing the SwiftUI spring's continuous interpolation was the remaining mechanism after three
//  earlier fixes; removing per-resize `setFrame` entirely closes that class of bug.
//
//  Constructor takes `NotchOverlayModel` (no wire emitter — plan §2: the model's actions call
//  straight into `RecordingSession`/the injected closures).
//
import AppKit
import AriViewModels
import SwiftUI

@MainActor
final class NotchPanelController {
    /// Extra click radius around the visible island's own footprint (plan: "a couple points of
    /// slack is fine") so the Stop/Record/Dismiss/open-app controls near the island's edge never
    /// feel clipped.
    private static let hitTestSlack: CGFloat = 6

    private let model: NotchOverlayModel
    private let environment = IslandEnvironment()

    private let panel: TopEdgePanel
    private let hostingView: ClickThroughHostingView

    /// Last size the SwiftUI island reported. Drives ONLY the hit-test `activeRect`
    /// (`updateActiveRect()`) now — the panel's own frame is fixed
    /// (`IslandGeometry.fixedPanelFrame`) and no longer follows this value.
    private var currentContentSize = CGSize(width: 190, height: 30)

    /// `nonisolated(unsafe)`: `deinit` isn't main-actor isolated, but it only ever calls
    /// `NotificationCenter.removeObserver`, which Apple documents as thread-safe — the ONLY
    /// access from off the main actor (plan §3 "deinit caveat"; ported precedent
    /// `IslandPanelController.swift:287-294`).
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(model: NotchOverlayModel) {
        self.model = model

        // MARK: Panel construction
        //
        // styleMask:
        //   .borderless        — no title bar / frame; we draw the whole surface.
        //   .nonactivatingPanel — the panel can receive mouse clicks (so the Stop/Record buttons
        //                         work) WITHOUT becoming key or activating the app. That is
        //                         exactly why we show with `orderFrontRegardless()` and NEVER
        //                         call `makeKey*`: a nonactivating panel routes clicks to its
        //                         controls while the user's frontmost app keeps focus.
        panel = TopEdgePanel(
            contentRect: NSRect(x: 0, y: 0, width: 190, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Transparent surface: only the black island shape shows.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow: the physical notch casts none, so a shadow would draw a rim around the
        // island and break the "part of the hardware" illusion.
        panel.hasShadow = false

        // Level: sit ABOVE the menu bar so the island can overlay the notch area. `.mainMenu + 3`
        // is the value proven notch apps use — comfortably above the menu-bar layer.
        panel.level = NSWindow.Level.mainMenu + 3

        // Show on every Space, float over fullscreen apps, don't move with the active window,
        // and never appear in Cmd-` window cycling.
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
        // Belt-and-suspenders: never let AppKit try to make this the key/main window
        // (reinforces the nonactivating click behavior).
        panel.isMovableByWindowBackground = false

        // MARK: SwiftUI host
        //
        // Built after `panel` exists so `onResize` can drive `panel` sizing. Stash a
        // placeholder root first, then assign the real one below (the closure captures `self`,
        // which must come after this init's other fields are set).
        hostingView = ClickThroughHostingView(
            rootView: IslandContainerView(
                model: model,
                environment: environment,
                onResize: { _ in },
                onPresentationChange: { _ in }
            )
        )
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        // CRITICAL for the integrated-notch look: an NSHostingView insets its content by the
        // window's safe area. Because this panel overlaps the menu-bar / notch strip, that inset
        // would push the island DOWN by the notch height, so the black shape floats in a gap
        // below the physical top edge instead of fusing with it. Clearing `safeAreaRegions` lets
        // the island's square top sit flush against the very top edge.
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView

        // Now wire the real callbacks (capture self).
        hostingView.rootView = IslandContainerView(
            model: model,
            environment: environment,
            onResize: { [weak self] size in
                self?.islandDidResize(to: size)
            },
            onPresentationChange: { [weak self] presentation in
                self?.applyPresentation(presentation)
            }
        )
    }

    // MARK: - Show / lifecycle

    /// Start following the active screen and reflect the CURRENT model state. The island is
    /// transient: the panel is NOT ordered front here — it starts hidden and is shown only when
    /// presentation becomes `.expanded` (recording/stopping or an upcoming alert).
    /// `applyPresentation` orders it in/out as the model changes; the same value is also pushed
    /// reactively from the SwiftUI container's `onPresentationChange`.
    func show() {
        installObservers()
        // Establish the FIXED frame (and a seeded hit-test rect) up front, once, rather than
        // waiting for the first presentation change — the frame no longer depends on it.
        refreshNotchEnvironment()
        reanchor()
        // Drive the initial state explicitly (idle -> hidden) so we don't depend on SwiftUI
        // `onAppear` timing before the panel is ever ordered in.
        applyPresentation(model.presentation)
    }

    /// Tear down observers and order the panel out. Called by `NotchOverlayCoordinator` when the
    /// `showNotchOverlay` preference is turned off.
    func hide() {
        panel.orderOut(nil)
        removeObservers()
    }

    /// Show or hide the panel based on presentation. `.hidden` -> `orderOut` (island disappears
    /// entirely, e.g. after Stop -> saved). `.expanded` / `.collapsed` -> `orderFrontRegardless()`
    /// (never `makeKey*`, so the user's frontmost app keeps focus). The panel's FRAME is no
    /// longer touched here — it is fixed (`reanchor()` only runs from `show()` and on screen-
    /// parameter changes) so a presentation change can never race a `setFrame` against the
    /// SwiftUI spring.
    private func applyPresentation(_ presentation: IslandPresentation) {
        switch presentation {
        case .hidden:
            panel.orderOut(nil)
        case .expanded, .collapsed:
            refreshNotchEnvironment()
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Primary-screen anchoring

    /// The display designated "main" in System Settings > Displays. In the global coordinate
    /// space that display's frame origin is always (0,0), which is the stable,
    /// active-window-independent way to identify it. Falls back to `NSScreen.main` then the
    /// first screen if (pathologically) none is at the origin.
    private var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func installObservers() {
        let nc = NotificationCenter.default

        // Screen layout changed (display added/removed, resolution/arrangement, notch geometry,
        // OR the user reassigning the main display): re-derive the notch environment and
        // re-anchor onto the (possibly new) primary display. We intentionally do NOT observe
        // app-activation — the island stays put on the primary display rather than following
        // the frontmost window.
        observers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenChange() }
        })
    }

    private func removeObservers() {
        let nc = NotificationCenter.default
        for token in observers {
            nc.removeObserver(token)
        }
        observers.removeAll()
    }

    private func handleScreenChange() {
        refreshNotchEnvironment()
        reanchor()
    }

    /// Called by the SwiftUI island whenever its rendered size changes (the collapsed <->
    /// expanded morph). The panel's FRAME no longer follows this (see `reanchor()`) — only the
    /// hit-test `activeRect` does, so clicks stay tight to the visible island without ever
    /// resizing the window mid-animation.
    private func islandDidResize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // Ignore sub-pixel churn.
        if abs(size.width - currentContentSize.width) < 0.5,
           abs(size.height - currentContentSize.height) < 0.5 {
            return
        }
        currentContentSize = size
        updateActiveRect()
    }

    /// Re-position the panel top-center of the PRIMARY screen with a FIXED frame
    /// (`IslandGeometry.fixedPanelFrame`) sized for the island's maximum content. Called ONLY on
    /// construction (`show()`) and on `didChangeScreenParametersNotification` — NEVER per content
    /// resize (`islandDidResize` above only updates the hit-test rect). This is the structural
    /// fix for the expand-animation top-gap artifact: the panel's frame now depends solely on
    /// screen parameters, so it can never race a `setFrame` against the SwiftUI spring mid-morph.
    /// We use the screen's full `.frame` (NOT `.visibleFrame`) so the island hugs the very top
    /// edge, over the menu bar.
    private func reanchor() {
        guard let screen = primaryScreen else { return }
        let frame = IslandGeometry.fixedPanelFrame(inScreen: screen.frame)
        // Snap to whole backing pixels: a fractional panel edge antialiases against whatever is
        // behind it — at the top seam that reads as a hairline "gap" with the physical notch.
        // Aligning outward keeps the panel covering at least its requested rect.
        let aligned = panel.backingAlignedRect(frame, options: .alignAllEdgesOutward)
        panel.setFrame(aligned, display: true)
        updateActiveRect()
    }

    /// Recomputes the hosting view's hit-test `activeRect` from the last-reported SwiftUI content
    /// size — the panel is now much bigger than the visible island for most of its life
    /// (`IslandGeometry.fixedPanelFrame` sizes it to the content CEILING, not the live size), so
    /// only this rect, not the panel's frame, tracks the collapsed <-> expanded morph.
    private func updateActiveRect() {
        let bounds = hostingView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let width = currentContentSize.width
        // The reported content size has `topBleed` already subtracted (`IslandContainerView
        // .visibleSize(of:)`) — the actual rendered (and thus hit-testable) island includes that
        // band back, since it's painted as part of the same shape fill.
        let renderedHeight = min(currentContentSize.height + IslandGeometry.topBleed, bounds.height)

        // The island is TOP-aligned within the panel
        // (`.frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top)`), i.e. its footprint
        // sits at the panel's visual top regardless of `NSHostingView`'s flip direction — handle
        // both explicitly rather than assume one.
        let topY: CGFloat = hostingView.isFlipped ? 0 : max(0, bounds.height - renderedHeight)

        let rect = CGRect(
            x: bounds.midX - width / 2.0,
            y: topY,
            width: width,
            height: renderedHeight
        )
        hostingView.activeRect = rect.insetBy(dx: -Self.hitTestSlack, dy: -Self.hitTestSlack)
    }

    /// Read the PRIMARY screen's physical notch (if any) into the chrome environment so the
    /// collapsed pill can merge with it. AppKit reads live here; the pure arithmetic is
    /// `IslandGeometry.notchWidth` (unit-tested in `AriKit`).
    private func refreshNotchEnvironment() {
        guard let screen = primaryScreen else {
            environment.notchSize = nil
            return
        }

        let notchHeight = screen.safeAreaInsets.top
        guard notchHeight > 0 else {
            // No top inset -> no notch on this screen.
            environment.notchSize = nil
            return
        }

        // Width from the two auxiliary top areas flanking the notch.
        let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightW = screen.auxiliaryTopRightArea?.width ?? 0
        if let width = IslandGeometry.notchWidth(
            screenWidth: screen.frame.width,
            leftAuxWidth: leftW,
            rightAuxWidth: rightW
        ) {
            environment.notchSize = CGSize(width: width, height: notchHeight)
        } else {
            // Inset present but aux areas unavailable: fall back to just the height so the
            // island still hugs the top; width comes from content.
            environment.notchSize = nil
        }
    }

    deinit {
        // Observers are removed on teardown. `deinit` isn't main-actor isolated, but
        // `NotificationCenter` removal is documented thread-safe (ported precedent from
        // `IslandPanelController.swift:287-294`).
        let nc = NotificationCenter.default
        for token in observers {
            nc.removeObserver(token)
        }
    }
}
