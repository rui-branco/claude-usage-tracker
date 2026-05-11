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
    dependencies: [
        .package(url: "https://github.com/PostHog/posthog-ios", from: "3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsageTracker",
            dependencies: [
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/ClaudeUsageTracker",
            exclude: ["Secrets.swift.example"],
            resources: [
                .copy("Resources/claude-menu-icon.png"),
                .copy("Resources/claude-icon.png"),
                .copy("Resources/codex-icon.png"),
                .copy("Resources/gemini-icon.png"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/AppIcon.icns")
            ]
        )
    ]
)
