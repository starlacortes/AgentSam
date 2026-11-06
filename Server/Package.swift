// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentSamServer",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(path: "../AgentSamCore"),
    ],
    targets: [
        .executableTarget(
            name: "AgentSamServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AgentSamCore", package: "AgentSamCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/AgentSamServer",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AgentSamServerTests",
            dependencies: [
                .target(name: "AgentSamServer"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "AgentSamCore", package: "AgentSamCore"),
            ],
            path: "Tests/AgentSamServerTests"
        )
    ]
)
