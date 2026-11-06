// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentSamCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AgentSamCore", targets: ["AgentSamCore"])],
    targets: [
        .target(
            name: "AgentSamCore",
            path: "Sources/AgentSamCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AgentSamCoreTests",
            dependencies: ["AgentSamCore"],
            path: "Tests/AgentSamCoreTests"
        ),
    ]
)
