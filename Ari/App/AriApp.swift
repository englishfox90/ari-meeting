//
//  AriApp.swift — @main entry point for the native macOS host (Phase 2 shell, S0).
//
//  Constructs the single `AppEnvironment` (which owns the one `AppDatabase` — plan principle 3,
//  single-DB-owner) and injects it into the view tree. No capture, no TCC yet: S0 only proves the
//  signed app launches, opens the Store DB, and shows a window (docs/plans/arikit-native-shell.md
//  §11 S0). Frameless / unified title bar per the confirmed UI direction (swift-ui-direction).
//
import AriViewModels
import SwiftUI

@main
struct AriApp: App {
    /// Gates process termination on in-flight MLX generation (see `AppDelegate.swift` for the
    /// crash this fixes: 2026-07-22, `NSApp.terminate` racing a live MLX summary generation).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The single root environment for the whole app. `@State` so its lifetime is the app's.
    @State private var environment = AppEnvironment()

    /// The ONE `@AppStorage` exception (docs/plans/settings-ui.md §2.4): theme must apply to the
    /// very first frame, before the DB even opens, so it is read here directly rather than
    /// through `AppDatabase.settings`. Shares its key with `AriViewModels.AppearanceStore` — both
    /// read/write the exact same `UserDefaults` entry, so the Settings screen's control and this
    /// root read never drift apart.
    @AppStorage(AppearanceStore.defaultsKey) private var storedAppearance = AppAppearance.system.rawValue

    /// Whether the opt-in menu-bar item is shown (docs/plans/menu-bar-item.md). Shares its
    /// `UserDefaults` key with `MenuBarVisibilityStore` (the Settings toggle's store), so flipping
    /// the toggle re-evaluates this scene and inserts/removes the `MenuBarExtra` live — the same
    /// `@AppStorage`/device-local-preference mechanism theme uses. Default OFF (parity with the
    /// Rust tray's macOS default).
    @AppStorage(MenuBarVisibilityStore.defaultsKey) private var showInMenuBar = false

    /// Stable identifier for the main window group, so the menu-bar item can reopen it via
    /// `openWindow(id:)` when every window has been closed.
    static let mainWindowID = "ari-main"

    init() {
        // Register bundled brand fonts before any view renders, so Bricolage headings resolve.
        AppFonts.register()
    }

    private var preferredColorScheme: ColorScheme? {
        switch AppAppearance(rawValue: storedAppearance) ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Split into per-scene computed properties: composing `WindowGroup` + a conditional
    /// `MenuBarExtra` + a `#if DEBUG` `Window` in one `@SceneBuilder` body overwhelmed the
    /// type-checker ("failed to produce diagnostic for expression" — an expression-too-complex
    /// choke it hits before it can name). Each scene now type-checks in isolation.
    var body: some Scene {
        mainWindow
        menuBarScene
        #if DEBUG
            designGalleryWindow
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootSplitView()
                .environment(environment)
                .preferredColorScheme(preferredColorScheme)
        }
        // Frameless / unified title bar — no top divider; toolbar + traffic lights float over the
        // panes (confirmed UI direction §10). `.hiddenTitleBar` + a unified toolbar gives the
        // content material a run to the top edge, matching the current app's overlay title bar.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        // Slightly wider than the old ~1100 design target so the meeting detail's two-pane
        // layout (threshold 800pt of detail width) clears comfortably beside the sidebar.
        .defaultSize(width: 1240, height: 760)
    }

    /// The menu-bar panel's root view (docs/plans/menu-bar-item.md) — the rich Marginalia panel
    /// (recording control + calendar brief), the Swift port of the frozen Rust tray. Extracted so
    /// the `MenuBarExtra` content closure is a single reference.
    private var menuBarContent: some View {
        MenuBarContentView()
            .environment(environment)
            .preferredColorScheme(preferredColorScheme)
    }

    /// Conditional presence via the `isInserted:` binding rather than a SceneBuilder `if`:
    /// wrapping a `MenuBarExtra` in `if showInMenuBar { … }` crashes the type-checker on this
    /// toolchain (Xcode 26.6 / Swift 6.3.3 — "failed to produce diagnostic for expression"); an
    /// unconditional `MenuBarExtra` compiles fine. `isInserted` is the intended API anyway — it
    /// inserts/removes the status item live as the Settings toggle flips `showInMenuBar`
    /// (docs/plans/menu-bar-item.md). `.window` style hosts the rich Marginalia panel.
    ///
    /// The status-bar glyph is the Ari brand mark, not a stock SF Symbol — so the item reads as
    /// *our* app in the bar. Uses `MenuBarMark` (a 27×18pt variant of `DictationMark`) rather than
    /// `DictationMark` itself: `MenuBarExtra(image:)` draws the asset at its intrinsic size and does
    /// NOT scale to the bar, so the 96×64pt artboard rendered enormous — the menu-bar asset carries
    /// explicit menu-bar-height dimensions. It's a template image, so macOS renders it monochrome
    /// and auto-adapts to light/dark bars. Live recording state is signalled inside the panel (the
    /// amber "Recording" badge), since a template menu-bar image can't carry an accent tint.
    private var menuBarScene: some Scene {
        MenuBarExtra("Ari", image: "MenuBarMark", isInserted: $showInMenuBar) {
            menuBarContent
        }
        .menuBarExtraStyle(.window)
    }

    #if DEBUG
        /// DEBUG-only Marginalia design-system validator (colors, type, buttons, materials, and
        /// Liquid Glass evaluation). Adds a "Design Gallery" item to the Window menu; never
        /// opens automatically and never ships in release — see `DesignGalleryView.swift`.
        private var designGalleryWindow: some Scene {
            Window("Design Gallery", id: "design-gallery") {
                DesignGalleryView()
            }
            .defaultSize(width: 980, height: 820)
        }
    #endif
}
