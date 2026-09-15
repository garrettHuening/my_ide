// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCodeHub",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "CForkpty",
            path: "Sources/CForkpty",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CCHMemory",
            path: "Sources/CCHMemory",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "CCHSubagents",
            dependencies: ["CCHMemory"],
            path: "Sources/CCHSubagents"
        ),
        .executableTarget(
            name: "cch-mcp",
            dependencies: ["CCHMemory"],
            path: "Sources/cch-mcp"
        ),
        .executableTarget(
            name: "ClaudeCodeHub",
            dependencies: [
                "CForkpty",
                "CCHMemory",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ClaudeCodeHub",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CCHSubagentsTests",
            dependencies: ["CCHSubagents"],
            path: "Tests/CCHSubagentsTests"
        ),
        .testTarget(
            name: "CCHMemoryTests",
            dependencies: ["CCHMemory"],
            path: "Tests/CCHMemoryTests"
        )
    ]
)
