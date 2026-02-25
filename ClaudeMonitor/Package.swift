// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeMonitor",
            path: "ClaudeMonitor"
        )
    ]
)
