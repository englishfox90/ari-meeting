//
//  IslandContainerView.swift
//  ari-notch
//
//  WS-H — the black island CHROME that wraps `NotchRootView`. Draws a shape with
//  SQUARE top corners (flush to the screen's top edge) and large ROUNDED BOTTOM
//  corners, so it reads as the notch/pill growing DOWNWARD from the top edge —
//  the look that sells the "integrated island" on both notched and non-notched
//  screens.
//
//  Two states, sprung between:
//    • collapsed — dormant (not recording, no upcoming meeting): a minimal black
//      pill. On a notched screen it is sized to the physical notch (width+height
//      supplied via `IslandEnvironment.notchSize`) so it MERGES with the real
//      notch; otherwise a small centered pill. No fake content (honest empty).
//    • expanded — recording OR an upcoming meeting: grows to fit `NotchRootView`
//      (the UC2 HUD or the UC1 alert).
//
//  Sizing: the view measures its own rendered size via a GeometryReader and
//  reports it up through `onResize`. The AppKit host (`IslandPanelController`)
//  resizes + re-anchors the NSPanel to follow that size continuously, so the
//  SwiftUI spring drives the morph and the panel's click region stays tight to
//  the visible island.
//
//  Dark-only chrome (the island is black by nature). The content views
//  (`RecordingHUDView` / `UpcomingMeetingView`) own their own colors; we only
//  add padding around them here — we do NOT edit those views.
//

import SwiftUI

// MARK: - Chrome-side environment (owned by the controller)

/// Live chrome inputs the SwiftUI island reads but that don't belong on the wire
/// model: the physical notch dimensions of the *currently active* screen (nil
/// when that screen has no notch). The controller updates this on screen /
/// active-app changes so the collapsed pill re-sizes to merge with the notch.
@MainActor
@Observable
final class IslandEnvironment {
    /// Physical notch size (width × height) of the active screen; `nil` when the
    /// active screen has no notch (external monitor / non-notched laptop).
    var notchSize: CGSize?

    init(notchSize: CGSize? = nil) {
        self.notchSize = notchSize
    }
}

// MARK: - Island shape (concave top, rounded bottom, animatable)

/// The signature notch/Dynamic-Island silhouette: the top edge is flush to the
/// screen's top, but each TOP corner is a CONCAVE fillet that flares outward so
/// the island's sides melt smoothly into the flat top edge (rather than meeting
/// it at a hard 90° square corner). The BOTTOM corners are the usual CONVEX
/// rounding, so the island reads as a pill growing DOWNWARD out of the top edge.
///
/// Both radii are `Animatable` (as an `AnimatablePair`) so the collapsed↔expanded
/// morph springs on either. Path construction mirrors DynamicNotchKit's
/// `NotchShape` (the concave top quad-curves + convex bottom quad-curves).
struct IslandShape: Shape {
    /// Concave flare at each top corner — how far the sides tuck in from the top
    /// edge. This is the curve that fuses the island into the screen's top edge.
    var topRadius: CGFloat
    /// Convex rounding at each bottom corner.
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Clamp so the two arcs on each side can't overrun the geometry on a
        // narrow/short island (the fallback pill is only 30pt tall).
        let top = max(0, min(topRadius, min(rect.width / 2.0, rect.height)))
        let bottom = max(0, min(bottomRadius, min(rect.width / 2.0 - top, rect.height - top)))

        var path = Path()

        // Top-left corner: from the very top-left, curve DOWN-and-IN (concave).
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        // Left side down to where the bottom rounding begins.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))

        // Bottom-left corner (convex).
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))

        // Bottom-right corner (convex).
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )

        // Right side back up to the top concave fillet.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))

        // Top-right corner: curve UP-and-OUT to the very top-right (concave).
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        // Close along the flush top edge.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}

// MARK: - Island container

struct IslandContainerView: View {
    var model: NotchModel
    var environment: IslandEnvironment
    let emitter: any NotchActionEmitter
    /// Reports the island's rendered size up to the AppKit host each layout pass.
    var onResize: (CGSize) -> Void
    /// Reports the derived presentation up to the AppKit host so it can show
    /// (`orderFrontRegardless`) or hide (`orderOut`) the panel. Computed in
    /// `body` so Observation tracks the model signals it depends on.
    var onPresentationChange: (IslandPresentation) -> Void

    /// Pure opaque black chrome — matches the physical notch exactly so the
    /// island fuses with it seamlessly (no translucent edge that reads as a
    /// border). The notch is pure black; so are we.
    private let chrome = Color.black

    // Non-notched collapsed pill fallback size.
    private let fallbackPill = CGSize(width: 190, height: 30)

    private var presentation: IslandPresentation {
        IslandPresentation.derive(
            isRecording: model.isRecording,
            hasUpcoming: model.upcomingMeeting != nil
        )
    }

    /// Concave top-corner radius per state — the fillet that fuses the island's
    /// sides into the flush top edge. Slightly larger when expanded so the wider
    /// body flares in gracefully; tighter when collapsed to hug the notch corner.
    private var topRadius: CGFloat {
        switch presentation {
        case .expanded:
            return 13
        case .collapsed, .hidden:
            return environment.notchSize != nil ? 8 : 10
        }
    }

    /// Convex bottom-corner radius per state.
    private var bottomRadius: CGFloat {
        switch presentation {
        case .expanded:
            return 22
        case .collapsed, .hidden:
            // Match the notch's own corner when merging; rounder pill otherwise.
            return environment.notchSize != nil ? 10 : 15
        }
    }

    /// Extra top inset for the expanded content so it clears the physical notch.
    /// Equals the active screen's notch height when notched, else 0 (external /
    /// non-notched displays need no inset — the shape just hugs the top edge).
    private var notchInset: CGFloat {
        guard let notch = environment.notchSize, notch.height > 1 else { return 0 }
        return notch.height
    }

    /// Collapsed pill dimensions: the physical notch size when present (so it
    /// disappears INTO the real notch), else a small centered pill.
    private var collapsedSize: CGSize {
        if let notch = environment.notchSize, notch.width > 1, notch.height > 1 {
            return notch
        }
        return fallbackPill
    }

    var body: some View {
        content
            .background(IslandShape(topRadius: topRadius, bottomRadius: bottomRadius).fill(chrome))
            .clipShape(IslandShape(topRadius: topRadius, bottomRadius: bottomRadius))
            // Spring the morph on the state change; the host follows the size.
            .animation(.snappy(duration: 0.34, extraBounce: 0.12), value: presentation)
            .animation(.snappy(duration: 0.34, extraBounce: 0.12), value: environment.notchSize)
            .background(sizeReporter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Belt-and-suspenders with the host's `safeAreaRegions = []`: whichever
            // macOS honors, the island must extend into the menu-bar/notch safe
            // area so its square top sits FLUSH against the physical top edge
            // rather than floating a notch-height gap below it.
            .ignoresSafeArea()
            // Reading `presentation` here (and above) tracks the model via
            // Observation; report show/hide transitions to the host. Fire once on
            // appear so the host reflects the initial (idle → hidden) state.
            .onAppear { onPresentationChange(presentation) }
            .onChange(of: presentation) { _, newValue in
                onPresentationChange(newValue)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .expanded:
            // Reuse the content views verbatim; only add chrome padding around
            // them (never edits the views themselves).
            //
            // On a NOTCHED display the black shape runs flush to the top edge to
            // fuse with the notch, but the physical notch would then cover the
            // first content row. So inset the content's top by the notch height
            // (`notchInset`) so REC/timer/title clear the notch and sit BELOW it —
            // the chrome still fills that inset region (black behind the notch).
            // On non-notched displays `notchInset` is 0, so external monitors are
            // unaffected.
            NotchRootView(model: model, emitter: emitter)
                .padding(.top, 8 + notchInset)
                .padding(.bottom, 12)
                .padding(.horizontal, 12)
                // Constrain so a long transcript line can't make the island
                // absurdly wide; the content views wrap within this.
                .frame(maxWidth: 460)
        case .collapsed:
            // Reserved / unused (derive never yields this). A minimal black pill,
            // sized to merge with the notch (or a small pill otherwise).
            Color.clear
                .frame(width: collapsedSize.width, height: collapsedSize.height)
        case .hidden:
            // Idle: nothing to draw — the host orders the panel out. Keep a
            // zero-size probe so layout stays valid until the panel is hidden.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Invisible probe that reports the island's rendered size to the host.
    private var sizeReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onResize(proxy.size) }
                .onChange(of: proxy.size) { _, newSize in onResize(newSize) }
        }
    }
}
