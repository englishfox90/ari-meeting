//
//  FixtureLoader.swift — locates and decodes the hand-authored wire fixtures (test support).
//
//  Resources are not declared in Package.swift (the Models stream must not touch it), so the
//  fixtures are located on disk relative to this file's path, mirroring the token-parity suite's
//  #filePath-walk approach. Replace with `Bundle.module` if resources are later registered.
//
import Foundation
@testable import AriKit

enum FixtureLoader {
    /// Directory holding the committed JSON fixtures, resolved from this file's location.
    private static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func data(_ name: String) throws -> Data {
        let url = directory.appendingPathComponent("\(name).json")
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try Models.jsonDecoder.decode(type, from: data(name))
    }
}
