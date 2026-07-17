// swift-tools-version: 6.0
//
//  Package.swift — Apple Helper sidecar (SwiftPM).
//
//  Produces the `apple-helper` executable that Tauri bundles as an externalBin
//  sidecar (`binaries/apple-helper-aarch64-apple-darwin`). Driven over
//  stdin/stdout NDJSON (one JSON object per line); see
//  Sources/apple-helper/Protocol.swift for the wire contract.
//
//  Platform floor is macOS 26. The Ari app is macOS-26-only and the SDK target
//  is arm64-apple-macosx26.0, so FoundationModels + Speech (both 26.0+ APIs)
//  import unconditionally with no availability guards.
//
//  Phase 1 implements ONLY `probe` (availability check) + `shutdown`. Later
//  phases add transcribe / summarize / ensureAssets.
//
import PackageDescription

let package = Package(
    name: "apple-helper",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "apple-helper",
            path: "Sources/apple-helper"
        ),
        .testTarget(
            name: "AppleHelperTests",
            dependencies: [
                "apple-helper"
            ],
            path: "Tests/AppleHelperTests"
        )
    ]
)
