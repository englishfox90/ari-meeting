// swift-tools-version: 6.0
//
//  Package.swift — AriKit (shared domain package for the Swift-native migration).
//
//  This is the shared Swift Package that the migration plan (plans/swift-migration-plan.md,
//  "Target architecture") describes: one package consumed by two app targets —
//  `Ari` (macOS, full engine, first) and `Ari Lite` (iOS/iPadOS, LATER — the same feature
//  set as the Mac app minus speaker identification, NOT read-only; Phase 6). Its intended
//  internal shape:
//
//      AriKit
//      ├── Models        meetings, transcripts, summaries, persons, series, profile facts
//      ├── Store         GRDB (local source of truth) + CloudKit sync (results layer)
//      ├── Recall        hybrid retrieval (BM25 ⊕ vector RRF), safety shell + tests preserved
//      ├── Context       SummaryContext assembly (owner + attendees + call type)
//      ├── Engine        ported capture/STT/summarization pipeline (Phase-gated)
//      └── DesignSystem  the Marginalia theme (colors/type/spacing/motion) — LIVE today
//
//  STATUS: mostly SCAFFOLD. Per the plan's WIP limits (principle 8), Models/Store/Recall/
//  Context/Engine carry no engine code yet — Phase 0 spikes (S1–S4) gate that. DesignSystem
//  is the one module that's real today: both future app targets need Marginalia themed
//  from their first screen (swift-conventions.md), so it isn't gated behind Phase 0. This
//  package exists now so the Claude-Code Swift tooling (/swift-build, /swift-test, the
//  PostToolUse SwiftLint/SwiftFormat hook, XcodeBuildMCP's swift_package_build/test) has a
//  real home to operate on from day one, and so net-new Swift work has somewhere to land.
//
//  Platform floor is macOS 26 / iOS 26 — the accepted "latest-OS-only" constraint
//  (plan principle 7): SpeechAnalyzer + FoundationModels are 26+. Swift 6 language mode
//  (strict concurrency) is pinned, mirroring today's "repositories-only" discipline for
//  the eventual GRDB store.
//
import PackageDescription

let package = Package(
    name: "AriKit",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0")
    ],
    products: [
        .library(
            name: "AriKit",
            targets: ["AriKit"]
        )
    ],
    targets: [
        .target(
            name: "AriKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AriKitTests",
            dependencies: ["AriKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
