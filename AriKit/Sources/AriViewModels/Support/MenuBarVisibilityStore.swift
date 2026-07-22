//
//  MenuBarVisibilityStore.swift — whether the menu-bar item is shown (docs/plans/menu-bar-item.md).
//
//  A device-local UI preference, exactly like theme (`AppearanceStore`): it must be read at the
//  app-SCENE level to insert/remove the `MenuBarExtra`, before/independent of the DB, and it is
//  never a sync candidate. The frozen Rust app likewise stored it in a local prefs file
//  (`app-preferences.json`), not the meeting DB — so it lives in `UserDefaults` under the key the
//  app root ALSO binds via `@AppStorage(MenuBarVisibilityStore.defaultsKey)`, and NOT in the
//  `setting` table. Both read/write the exact same key, so the Settings toggle and the app-root's
//  scene gate never drift apart (mirrors `AppearanceStore`).
//
import Foundation

/// Thin `UserDefaults` accessor for `showInMenuBar` — gives `SettingsViewModel` a uniform get/set
/// surface for the one General control that gates a Scene rather than a `SettingsRepository` row.
public struct MenuBarVisibilityStore: Sendable {
    /// Shared with `AriApp`'s `@AppStorage(MenuBarVisibilityStore.defaultsKey)` binding — do not
    /// rename independently.
    public static let defaultsKey = "showInMenuBar"

    /// No stored `UserDefaults` instance (it isn't `Sendable`) — every accessor goes through the
    /// shared `.standard` suite directly, which is itself thread-safe by Apple's own contract
    /// (mirrors `AppearanceStore`).
    public init() {}

    /// Default OFF (parity with the Rust tray's macOS `default_menu_bar_enabled == false`).
    /// `UserDefaults.bool(forKey:)` returns `false` for an absent key, so the default needs no
    /// explicit registration.
    public var isVisible: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }
}
