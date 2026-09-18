// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftOpenWork",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SwiftOpenWork",
            targets: ["SwiftOpenWork"]
        ),
        // What the Xcode app links: every module in one dynamic library. See project.yml.
        .library(
            name: "SwiftOpenWorkKit",
            type: .dynamic,
            targets: [
                "SwiftOpenWorkCore",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        // Models and small utilities: no dependencies on the rest of the app, and the first
        // module compiled in the Swift 6 language mode.
        .target(
            name: "SwiftOpenWorkCore",
            path: "Sources/SwiftOpenWorkCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "SwiftOpenWork",
            dependencies: [
                "SwiftOpenWorkCore",
                .product(name: "Yams", package: "yams"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                // Vision checkpoints need their own factory; LLMModelFactory builds a text-only
                // pipeline that silently drops images. See NativeMLXService.loadContainer…
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/SwiftOpenWork",
            resources: [
                .process("../../Resources")
            ],
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-Wno-c++17-extensions"])
            ],
            // Swift 6 toolchain, Swift 5 language mode: the app has only ever compiled with
            // minimal concurrency checking. Modules move to `.v6` one at a time.
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        ),
        .testTarget(
            name: "SwiftOpenWorkTests",
            dependencies: [
                "SwiftOpenWorkCore",
                .target(name: "SwiftOpenWork")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
