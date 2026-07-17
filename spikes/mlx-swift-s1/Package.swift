// swift-tools-version: 6.1
// mlx-swift-s1 — throwaway S1 spike package. NOT part of AriKit/product code.
// Proves whether mlx-swift-lm (the Swift MLX LLM package) can load+run
// dense Gemma 4 E4B (4-bit) and a Qwen-class 4B (MLX 4-bit) for text-only
// meeting-summary generation, matching the Python mlx-lm bake-off already
// running in tools/prompt-harness/.

import PackageDescription

let package = Package(
    name: "mlx-swift-s1",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "mlx-swift-s1",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/mlx-swift-s1"
        )
    ]
)
