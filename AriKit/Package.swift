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
//  STATUS: mostly SCAFFOLD. Per the plan's WIP limits (principle 8), Store/Recall/Context/
//  Engine carry no engine code yet — Phase 0 spikes (S1–S4) gate that. Two modules are real
//  today: DesignSystem (both future app targets need Marginalia themed from their first screen,
//  swift-conventions.md, so it isn't gated behind Phase 0) and Models — the shared domain
//  value types, ported 2026-07-17 (persistence-agnostic, so not spike-gated; the GRDB Store
//  over them is still Phase 3.1). See docs/plans/arikit-models.md. This
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

/// Store dependency: plain GRDB, NOT Point-Free SQLiteData — see docs/plans/arikit-store.md §0.1(3)
/// and §10 risk (d). SQLiteData's released API (checked 2026-07-17, v1.7.0) is built around its own
/// `@Table` macro + swift-structured-queries query builder + `@FetchAll` property wrappers — a
/// different paradigm from, not a superset of, the plain `FetchableRecord`/`PersistableRecord`
/// record shape this plan specifies (§2.1, the `grdb` skill). Adopting it now would mean either
/// fighting the macro layer to get plain records, or adopting the macro layer itself (an
/// out-of-scope design change) — plus a heavy transitive dependency pull (swift-structured-queries,
/// swift-sharing, swift-perception, swift-tagged, swift-collections, swift-custom-dump,
/// swift-snapshot-testing, swift-dependencies) for zero benefit in this foundation slice (CloudKit
/// sync isn't wired until Phase 5.5). SQLiteData itself depends on GRDB.swift ~> 7.6, so this
/// package still rests on exactly the GRDB semantics SQLiteData will eventually layer over —
/// revisit the SQLiteData adoption at the Phase 5.5 CloudKit-wiring step, per §0.1(3).
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
        ),
        // macOS-only: capture's pure DSP core (arikit-native-shell.md §2.2, §11 S1). Depends on
        // AriKit (for the `PCMWindow` seam type), never the reverse, so `AriKit.Engine` stays
        // capture-agnostic and iOS-buildable. The live-device classes (SystemAudioTap,
        // MicrophoneCapture, CaptureCoordinator — plan §11 S2-S4) are NOT part of this slice.
        .library(
            name: "AriCapture",
            targets: ["AriCapture"]
        ),
        // Phase 2 slice S6 (docs/plans/arikit-native-read-ui.md) — read-UI view models.
        // @Observable-MVVM state, pure of SwiftUI/AVFoundation: depends only on AriKit
        // (AppDatabase + Sendable repositories) so it tests headlessly via `swift test` over
        // AppDatabase.makeInMemory(). SwiftUI views + AVPlayer live in the `Ari` app target.
        .library(
            name: "AriViewModels",
            targets: ["AriViewModels"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        // AriKitEngineMLX-only dependencies (plan §1.2, docs/plans/arikit-engine-extras.md). Core
        // `AriKit` does NOT depend on these — they exist only so the `AriKitEngineMLX` target below
        // can resolve them; core AriKit stays headless/Metal-toolchain-free.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "AriKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AriKitTests",
            dependencies: ["AriKit"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Phase 3.2 slice S1 (docs/plans/arikit-native-shell.md §11) — the pure, headless-
        // testable DSP core: Resampler, AudioMixer, SpeechVAD segmenter, AACRecorder,
        // IncrementalSaver. All AVFoundation-backed code is `#if os(macOS)`-gated in source
        // (the product is conceptually macOS-only per plan §2.2; only the macOS `Ari` app
        // target ever depends on it — `Ari Lite`/iOS supplies its own mic-only capture, Phase 6).
        .target(
            name: "AriCapture",
            dependencies: ["AriKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AriCaptureTests",
            dependencies: ["AriCapture", "AriKit"],
            // D6 (docs/plans/arikit-diarization.md §5, swift-M2): the bundled fixture m4a for
            // `DiarizationAudioLoaderTests` resolves via `Bundle.module`.
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Phase 2 slice S6 — read-UI view models (docs/plans/arikit-native-read-ui.md §2.1).
        .target(
            name: "AriViewModels",
            dependencies: ["AriKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AriViewModelsTests",
            dependencies: ["AriViewModels", "AriKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Track E (docs/plans/arikit-engine-extras.md §1) — the on-device MLX summary backend.
        // Separate product/target depending on `AriKit`, never the reverse (§1.2): core `AriKit`
        // gains no MLX dependency, so `swift build`/`swift test AriKit` stays headless and
        // Metal-toolchain-free. Text-only client — `MLXVLM` (the spike's VLM loader) is dropped.
        //
        // Swift-6 mode (§1.5b / §6-1): pinned to `.swiftLanguageMode(.v5)` as a documented,
        // ISOLATED exception — see the target's `swiftSettings` comment below for why. This
        // exception is scoped to `AriKitEngineMLX` only; it never leaks to core `AriKit`, which
        // stays `.v6` above.
        .target(
            name: "AriKitEngineMLX",
            dependencies: [
                "AriKit",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            swiftSettings: [
                // ← §1.5b / §6-1: `mlx-swift-lm` 3.31.4's transitive graph (MLXArray-carrying
                // closures, `consuming` parameters designed for Swift 5-style ownership, etc.)
                // does not compile clean under `.swiftLanguageMode(.v6)` strict concurrency when
                // this target imports `ChatSession`/`ModelContainer` types directly. The spike
                // itself (`spikes/mlx-swift-s1/Package.swift`) also compiled WITHOUT
                // `.swiftLanguageMode(.v6)` pinned. Per `swift-conventions.md`'s sanctioned escape
                // hatch ("pin the target only... as a documented exception"), this target is
                // pinned to `.v5`. Core `AriKit` (above) is unaffected and stays `.v6`.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AriKitEngineMLXTests",
            dependencies: ["AriKitEngineMLX"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
