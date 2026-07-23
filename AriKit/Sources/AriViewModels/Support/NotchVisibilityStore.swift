//
//  NotchVisibilityStore.swift — whether the notch overlay panel is shown
//  (docs/plans/notch-panel-absorption.md §6).
//
//  A device-local UI preference, byte-for-byte sibling of `MenuBarVisibilityStore.swift`: it must
//  be read independent of/before the DB to insert/remove the `NSPanel` host, and it is never a
//  sync candidate. Key `showNotchOverlay`, default OFF — a Swift-native preference with no
//  imported counterpart from the frozen Rust app's own `settings.json` notch flag.
//
import Foundation

/// Thin `UserDefaults` accessor for `showNotchOverlay` — gives `SettingsViewModel` a uniform
/// get/set surface for the notch-overlay toggle, mirroring `MenuBarVisibilityStore`.
public struct NotchVisibilityStore: Sendable {
    /// Observed by `NotchOverlayCoordinator` (app target) via `UserDefaults.didChangeNotification`
    /// to insert/remove the panel live — do not rename independently.
    public static let defaultsKey = "showNotchOverlay"

    /// No stored `UserDefaults` instance (it isn't `Sendable`) — every accessor goes through the
    /// shared `.standard` suite directly, which is itself thread-safe by Apple's own contract
    /// (mirrors `MenuBarVisibilityStore`).
    public init() {}

    /// Default OFF (decided 2026-07-22). `UserDefaults.bool(forKey:)` returns `false` for an
    /// absent key, so the default needs no explicit registration.
    public var isVisible: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }
}
