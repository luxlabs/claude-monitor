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
            path: "ClaudeMonitor",
            // Used by the Xcode project only.
            exclude: ["ClaudeMonitor.entitlements", "Assets.xcassets"]
        ),
        .testTarget(
            name: "ClaudeMonitorTests",
            dependencies: ["ClaudeMonitor"],
            path: "Tests/ClaudeMonitorTests"
        ),
    ]
)
