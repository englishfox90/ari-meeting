// swift-tools-version: 6.2
// fluidaudio-s3 — throwaway S3 spike package. NOT part of AriKit/product code.
// Proves whether FluidAudio's offline (pyannote community-1) CoreML diarization
// pipeline produces plausible speaker segments on real meeting audio, emitted
// as RTTM for scoring against the tools/diarization-sweep rig's DER harness.
// See spikes/fluidaudio-s3/README.md for context.

import PackageDescription

let package = Package(
    name: "fluidaudio-s3",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "fluidaudio-s3",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/fluidaudio-s3"
        )
    ]
)
