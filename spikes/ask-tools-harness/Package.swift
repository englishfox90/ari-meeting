// swift-tools-version: 6.1
// ask-tools-harness — throwaway Slice 1 risk-validation spike. NOT part of AriKit/product code.
//
// Validates docs/plans/ask-meetings-agentic-tools.md §9 risks 1/2/5 by calling the PRODUCTION
// `MLXClient.respondWithTools` directly (via a local path dependency on ../../AriKit), rather than
// duplicating its tool-loop logic — so this harness exercises the exact code path Slice 2 will
// build on. Reuses the app's real, already-downloaded HF model cache (~/.cache/huggingface/hub)
// — never triggers a fresh multi-GB download; skips the run honestly if nothing is cached (see
// Entry.swift).

import PackageDescription

let package = Package(
    name: "ask-tools-harness",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(path: "../../AriKit")
    ],
    targets: [
        .executableTarget(
            name: "ask-tools-harness",
            dependencies: [
                .product(name: "AriKit", package: "AriKit"),
                .product(name: "AriKitEngineMLX", package: "AriKit")
            ],
            path: "Sources/ask-tools-harness"
        )
    ]
)
