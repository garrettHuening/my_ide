// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentdSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SpikeShared", path: "Sources/SpikeShared"),
        .executableTarget(name: "SpikeApp", dependencies: ["SpikeShared"], path: "Sources/SpikeApp"),
        .executableTarget(name: "spike-agentd", dependencies: ["SpikeShared"], path: "Sources/spike-agentd"),
        .executableTarget(name: "spike-client", dependencies: ["SpikeShared"], path: "Sources/spike-client"),
    ]
)
