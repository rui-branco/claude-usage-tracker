// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageTracker",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeUsageTracker", targets: ["ClaudeUsageTracker"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsageTracker",
            path: "Sources/ClaudeUsageTracker"
        )
    ]
)
