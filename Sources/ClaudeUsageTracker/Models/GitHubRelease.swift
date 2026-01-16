import Foundation

// MARK: - GitHub API Response Models

struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String
    let htmlUrl: String
    let assets: [GitHubAsset]
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case assets
        case publishedAt = "published_at"
    }

    /// Returns the first ZIP asset suitable for download
    var zipAsset: GitHubAsset? {
        assets.first { $0.name.hasSuffix(".zip") }
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - Semantic Version

struct AppVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parse version string like "1.2.3" or "v1.2.3"
    init?(string: String) {
        var versionString = string.trimmingCharacters(in: .whitespaces)

        // Remove leading "v" if present
        if versionString.lowercased().hasPrefix("v") {
            versionString = String(versionString.dropFirst())
        }

        let components = versionString.split(separator: ".").compactMap { Int($0) }

        guard components.count >= 2 else { return nil }

        self.major = components[0]
        self.minor = components[1]
        self.patch = components.count > 2 ? components[2] : 0
    }

    /// Get current app version from bundle or Info.plist file
    static var current: AppVersion? {
        // Try bundle first (works for release .app builds)
        if let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return AppVersion(string: versionString)
        }

        // Fallback: try reading Info.plist directly (for development builds via swift build)
        if let plistPath = findInfoPlist(),
           let plistData = FileManager.default.contents(atPath: plistPath),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
           let versionString = plist["CFBundleShortVersionString"] as? String {
            return AppVersion(string: versionString)
        }

        return nil
    }

    /// Find Info.plist in common locations relative to executable
    private static func findInfoPlist() -> String? {
        let fileManager = FileManager.default

        // Get executable path and work backwards to find project root
        let executablePath = Bundle.main.executablePath ?? ""
        var currentPath = URL(fileURLWithPath: executablePath).deletingLastPathComponent()

        // Search up to 10 parent directories for Info.plist
        for _ in 0..<10 {
            let plistPath = currentPath.appendingPathComponent("Info.plist").path
            if fileManager.fileExists(atPath: plistPath) {
                return plistPath
            }
            currentPath = currentPath.deletingLastPathComponent()
        }

        return nil
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}
