// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentSamCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AgentSamCore", targets: ["AgentSamCore"])],
    targets: [
        .target(
            name: "AgentSamCore",
            path: "Sources/AgentSamCore"
        )
    ]
)
