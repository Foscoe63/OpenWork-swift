// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWorkSwift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "OpenWorkSwift",
            targets: ["OpenWorkSwift"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-jinja.git", "2.0.0"..<"2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "OpenWorkSwift",
            dependencies: [
                .product(name: "Yams", package: "yams"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources",
            resources: [
                .process("../Resources")
            ],
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-Wno-c++17-extensions"])
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        ),
        .testTarget(
            name: "OpenWorkSwiftTests",
            dependencies: [
                .target(name: "OpenWorkSwift")
            ]
        )
    ]
)
