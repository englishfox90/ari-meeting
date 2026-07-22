//
//  AppearanceStore.swift — the theme accessor `SettingsViewModel` reads/writes
//  (docs/plans/settings-ui.md §2.4).
//
//  Theme is DELIBERATELY not a `setting` table row: it must apply to the very first frame
//  (before the DB even opens), is intrinsically device-local, and is never a sync candidate.
//  The durable store is plain `UserDefaults` under the key the app root ALSO binds via
//  `@AppStorage("appAppearance")` — both read/write the exact same key, so the VM's surface and
//  the app-root's first-frame read never drift apart.
//
import Foundation

/// The three appearance choices (System/Light/Dark).
public enum AppAppearance: String, Sendable, CaseIterable {
    case system
    case light
    case dark
}

/// Thin `UserDefaults` accessor for `appAppearance` — gives `SettingsViewModel` a uniform
/// get/set surface for the one control that isn't backed by `SettingsRepository`.
public struct AppearanceStore: Sendable {
    /// Shared with `AriApp`'s `@AppStorage("appAppearance")` binding — do not rename independently.
    public static let defaultsKey = "appAppearance"

    /// No stored `UserDefaults` instance (it isn't `Sendable`) — every accessor goes through the
    /// shared `.standard` suite directly, which is itself thread-safe by Apple's own contract.
    public init() {}

    public var appearance: AppAppearance {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) else { return .system }
            return AppAppearance(rawValue: raw) ?? .system
        }
        nonmutating set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey)
        }
    }
}
