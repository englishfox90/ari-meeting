// swift-tools-version: 6.2
// speechanalyzer-s2 — throwaway S2 spike package. NOT part of AriKit/product code.
// Proves whether Apple's SpeechAnalyzer (macOS 26, SpeechTranscriber +
// DictationTranscriber modules) matches the shipped Parakeet transcription
// on real meeting audio. See spikes/speechanalyzer-s2 report / task for context.

import PackageDescription

let package = Package(
    name: "speechanalyzer-s2",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "speechanalyzer-s2",
            path: "Sources/speechanalyzer-s2"
        )
    ]
)
