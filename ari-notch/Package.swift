// swift-tools-version: 5.9
//
//  Package.swift — Ari Notch sidecar (SwiftPM).
//
//  Produces the `ari-notch` executable that Tauri bundles as an externalBin
//  sidecar (`binaries/ari-notch-aarch64-apple-darwin`). Driven over stdin/stdout
//  NDJSON; see Sources/AriNotch/Protocol.swift for the wire contract.
//
//  Platform floor is macOS 14 (SwiftUI @Observable / the Observation framework
//  need 14+). This is far below the Ari app's macOS 26 runtime floor, so it
//  imposes no additional constraint on the shipped product.
//
//  Rendering host: a CUSTOM simulated Dynamic Island (WS-H). We DROPPED
//  DynamicNotchKit because on a non-notched display it falls back to a detached
//  floating capsule rather than the integrated island we want. Our own
//  AppKit NSPanel host (`IslandPanelController`) + SwiftUI chrome
//  (`IslandContainerView`) draw a top-center island that fuses with the
//  physical notch when present and simulates a black pill when absent. No
//  external UI dependency remains.
//
import PackageDescription

let package = Package(
    name: "ari-notch",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ari-notch",
            path: "Sources/AriNotch"
        ),
        .testTarget(
            name: "AriNotchTests",
            dependencies: [
                "ari-notch"
            ],
            path: "Tests/AriNotchTests"
        )
    ]
)
