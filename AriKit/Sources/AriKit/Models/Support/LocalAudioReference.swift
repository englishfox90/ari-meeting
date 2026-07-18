//
//  LocalAudioReference.swift — local-only audio path newtype (plan §6, decision 0.6).
//
//  Encodes the results/audio split (migration principle 5): a meeting's audio is referenced by
//  a **device-local path**, never carried as bytes in a synced domain type. This newtype makes
//  "this String is a local audio location, not a syncable blob" explicit at the type level and
//  keeps every domain type free of audio `Data`.
//
//  It wraps the Rust `MeetingModel.folder_path` value and encodes transparently as a bare
//  string, so storage/wire shape is unchanged.
//
import Foundation

public struct LocalAudioReference: RawRepresentable, Sendable, Hashable, Codable,
    CustomStringConvertible {
    /// Device-local filesystem path to the meeting's audio/recording folder. Never synced.
    public let path: String

    public var rawValue: String { path }

    public init(rawValue: String) {
        path = rawValue
    }

    public init(path: String) {
        self.path = path
    }

    public var description: String { path }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        path = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}
