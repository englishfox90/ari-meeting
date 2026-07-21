//
//  AriApp.swift — @main entry point for the native macOS host (Phase 2 shell, S0).
//
//  Constructs the single `AppEnvironment` (which owns the one `AppDatabase` — plan principle 3,
//  single-DB-owner) and injects it into the view tree. No capture, no TCC yet: S0 only proves the
//  signed app launches, opens the Store DB, and shows a window (docs/plans/arikit-native-shell.md
//  §11 S0). Frameless / unified title bar per the confirmed UI direction (swift-ui-direction).
//
import SwiftUI

@main
struct AriApp: App {
    /// The single root environment for the whole app. `@State` so its lifetime is the app's.
    @State private var environment = AppEnvironment()

    init() {
        // Register bundled brand fonts before any view renders, so Bricolage headings resolve.
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environment(environment)
        }
        // Frameless / unified title bar — no top divider; toolbar + traffic lights float over the
        // panes (confirmed UI direction §10). `.hiddenTitleBar` + a unified toolbar gives the
        // content material a run to the top edge, matching the current app's overlay title bar.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        // Design default window target ~1100×700 (design-system.md); comfortable for the
        // 3-column read shell without forcing a size on the user after first launch.
        .defaultSize(width: 1120, height: 720)

        #if DEBUG
        // DEBUG-only Marginalia design-system validator (colors, type, buttons, materials, and
        // Liquid Glass evaluation). Adds a "Design Gallery" item to the Window menu; never
        // opens automatically and never ships in release — see `DesignGalleryView.swift`.
        Window("Design Gallery", id: "design-gallery") {
            DesignGalleryView()
        }
        .defaultSize(width: 980, height: 820)
        #endif
    }
}
