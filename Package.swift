// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenWorkSwift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "OpenWorkSwift",
            targets: ["OpenWorkSwift"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "OpenWorkSwift",
            dependencies: [],
            path: "Sources",
            resources: [
                .process("../Resources")
            ]
        )
    ]
)
