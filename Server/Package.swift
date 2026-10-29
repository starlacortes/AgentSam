// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentSamServer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(path: "../AgentSamCore"),
    ],
    targets: [
        .executableTarget(
            name: "AgentSamServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AgentSamCore", package: "AgentSamCore"),
            ],
            path: "Sources/AgentSamServer"
        )
    ]
)
