//
//  NotchStyleParityTests.swift — docs/plans/notch-panel-absorption.md §7 suite 7.
//
//  Walks to `Ari/UI/Notch/` (the app target — the sidecar tests' own fixture-resolution
//  pattern, via `#filePath`) and asserts NO hex color literal and NO `E8A020` (the old
//  `NotchPalette.amber` value) appears anywhere in the ported notch sources — the "old amber
//  must not survive the port to Marginalia" gate as a TEST, not just an intention (plan §5).
//
//  The one documented exception is the pure-black island chrome (`Color.black`,
//  `IslandContainerView.swift`) — deliberately NOT a Marginalia token (plan §5: "the island
//  chrome stays pure black... deliberately not a token"). `Color.black` is a named color, not a
//  hex/RGB literal, so it never trips the regexes below; no allowlisting is needed for it.
//
import Foundation
import Testing

@Suite("NotchStyleParityTests")
struct NotchStyleParityTests {
    /// `#filePath` for THIS file is
    /// `.../AriKit/Tests/AriViewModelsTests/NotchStyleParityTests.swift`; walk up out of
    /// `AriKit/` to the repo root, then down into the app target's notch folder.
    private static var notchSourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AriViewModelsTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // AriKit/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Ari/UI/Notch", isDirectory: true)
    }

    private static var notchSwiftFiles: [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: notchSourcesDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// `Color(hex: 0xRRGGBB)` — the sidecar's own hex-literal init, dead with `NotchStyle.swift`.
    private static let hexInitLiteral = try! NSRegularExpression(pattern: "0x[0-9A-Fa-f]{6}")
    /// `"#RRGGBB"` string literals (CSS/web-style hex).
    private static let hexStringLiteral = try! NSRegularExpression(pattern: "#[0-9A-Fa-f]{6}\\b")

    @Test("Ari/UI/Notch exists and was ported")
    func notchSourcesDirectoryIsPopulated() {
        let files = Self.notchSwiftFiles
        #expect(!files.isEmpty, "expected ported notch sources under \(Self.notchSourcesDirectory.path)")
    }

    @Test("no E8A020 (the old NotchPalette.amber value) survives the port")
    func noOldAmberHexValue() throws {
        for file in Self.notchSwiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !contents.contains("E8A020"),
                "\(file.lastPathComponent) still contains the old amber hex value E8A020"
            )
        }
    }

    @Test("no hex color literal (Color(hex:) or #RRGGBB string) appears in the notch sources")
    func noHexColorLiterals() throws {
        for file in Self.notchSwiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..., in: contents)

            let hexInitMatches = Self.hexInitLiteral.numberOfMatches(in: contents, range: range)
            #expect(hexInitMatches == 0, "\(file.lastPathComponent) contains a 0xRRGGBB hex-init literal")

            let hexStringMatches = Self.hexStringLiteral.numberOfMatches(in: contents, range: range)
            #expect(hexStringMatches == 0, "\(file.lastPathComponent) contains a #RRGGBB hex string literal")
        }
    }
}
