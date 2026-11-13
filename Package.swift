// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDeckCore", targets: ["AgentDeckCore"]),
        .executable(name: "AgentDeckApp", targets: ["AgentDeckApp"]),
        .executable(name: "agentdeck", targets: ["AgentDeckCLI"])
    ],
    targets: [
        .target(name: "AgentDeckCore"),
        .executableTarget(name: "AgentDeckApp", dependencies: ["AgentDeckCore"]),
        .executableTarget(name: "AgentDeckCLI", dependencies: ["AgentDeckCore"]),
        .testTarget(name: "AgentDeckCoreTests", dependencies: ["AgentDeckCore"])
    ],
    swiftLanguageModes: [.v5]
)
