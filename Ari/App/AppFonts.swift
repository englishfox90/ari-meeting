//
//  AppFonts.swift — registers the bundled brand fonts with Core Text at launch so
//  `Font.custom("Bricolage Grotesque", …)` in AriKit's DesignSystem resolves the real face
//  (BRAND.md §5: Bricolage headings over SF Pro body). AriKit does NOT bundle the font — it's an
//  app-bundle resource, registered here before any view body renders.
//
import CoreText
import Foundation

enum AppFonts {
    /// Registers every bundled `.ttf` with the process font manager. Idempotent-safe: a
    /// re-registration (`alreadyRegistered`) is ignored, so this can run on every launch.
    static func register() {
        let urls =
            (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
                + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in Set(urls) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already-registered is benign; anything else is worth a log (no crash — a
                // missing brand font degrades to the SF fallback, never a fake state).
                if let error = error?.takeUnretainedValue() {
                    let code = CFErrorGetCode(error)
                    if code != CTFontManagerError.alreadyRegistered.rawValue {
                        NSLog("AppFonts: failed to register \(url.lastPathComponent): \(error)")
                    }
                }
            }
        }
    }
}
