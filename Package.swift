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
        .executableTarget(
            name: "ClaudeCodeHub",
            dependencies: [
                "CForkpty",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ClaudeCodeHub",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
