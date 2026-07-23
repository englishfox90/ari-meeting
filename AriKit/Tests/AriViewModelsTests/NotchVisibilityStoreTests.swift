//
//  NotchVisibilityStoreTests.swift — docs/plans/notch-panel-absorption.md §7 suite 6.
//
//  Mirrors `MenuBarVisibilityStore`'s own coverage (`SettingsViewModelTests.menuBarVisibilityStoreRoundTrips`).
//
import Foundation
import Testing
@testable import AriViewModels

@Suite("NotchVisibilityStore")
struct NotchVisibilityStoreTests {
    @Test("default false on an absent key; set/get round-trips through UserDefaults")
    func defaultsFalseAndRoundTrips() {
        let store = NotchVisibilityStore()
        // Save + restore the shared key so this test never leaks into others.
        let original = UserDefaults.standard.object(forKey: NotchVisibilityStore.defaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: NotchVisibilityStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: NotchVisibilityStore.defaultsKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: NotchVisibilityStore.defaultsKey)
        #expect(store.isVisible == false) // absent key → honest OFF default

        store.isVisible = true
        #expect(store.isVisible == true)
        #expect(UserDefaults.standard.bool(forKey: NotchVisibilityStore.defaultsKey) == true)

        store.isVisible = false
        #expect(store.isVisible == false)
    }
}
