import Foundation
import AppKit

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    // MARK: - Published Properties

    @Published var isChecking = false
    @Published var latestRelease: GitHubRelease?
    @Published var updateAvailable = false
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var lastError: String?
    @Published var checkResult: UpdateCheckResult?

    // MARK: - Constants

    private let repoOwner = "rui-branco"
    private let repoName = "claude-usage-tracker"

    private var githubAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    // MARK: - UserDefaults Keys

    private let skippedVersionKey = "skippedUpdateVersion"

    // MARK: - Check Result

    enum UpdateCheckResult: Equatable {
        case upToDate
        case updateAvailable(version: String)
        case error(String)
    }

    // MARK: - Public Methods

    /// Check for updates from GitHub releases
    @discardableResult
    func checkForUpdates() async -> UpdateCheckResult {
        guard !isChecking else {
            return checkResult ?? .error("Check already in progress")
        }

        isChecking = true
        lastError = nil
        checkResult = nil

        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            latestRelease = release

            guard let currentVersion = AppVersion.current,
                  let releaseVersion = AppVersion(string: release.tagName) else {
                let result = UpdateCheckResult.error("Could not parse version")
                checkResult = result
                return result
            }

            // Check if update is available and not skipped
            if releaseVersion > currentVersion && !isVersionSkipped(release.tagName) {
                updateAvailable = true
                let result = UpdateCheckResult.updateAvailable(version: release.tagName)
                checkResult = result
                return result
            } else {
                updateAvailable = false
                let result = UpdateCheckResult.upToDate
                checkResult = result
                return result
            }
        } catch {
            let message = error.localizedDescription
            lastError = message
            let result = UpdateCheckResult.error(message)
            checkResult = result
            return result
        }
    }

    /// Download the latest update ZIP to Downloads folder
    func downloadUpdate() async throws -> URL {
        guard let release = latestRelease,
              let asset = release.zipAsset else {
            throw UpdateError.noAssetFound
        }

        guard let downloadURL = URL(string: asset.browserDownloadUrl) else {
            throw UpdateError.invalidURL
        }

        isDownloading = true
        downloadProgress = 0

        defer { isDownloading = false }

        // Get Downloads folder
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let destinationURL = downloadsURL.appendingPathComponent(asset.name)

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destinationURL)

        // Download with progress tracking
        let (localURL, _) = try await downloadWithProgress(from: downloadURL, expectedSize: asset.size)

        // Move to Downloads
        try FileManager.default.moveItem(at: localURL, to: destinationURL)

        downloadProgress = 1.0
        return destinationURL
    }

    /// Install update from downloaded ZIP
    func installUpdate(from zipURL: URL) async throws {
        let fileManager = FileManager.default

        // Get the directory containing the ZIP
        let downloadDir = zipURL.deletingLastPathComponent()
        let appName = "ClaudeUsageTracker.app"
        let extractedAppURL = downloadDir.appendingPathComponent(appName)

        // Remove previously extracted app if exists
        try? fileManager.removeItem(at: extractedAppURL)

        // Unzip using ditto (preserves attributes)
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzipProcess.arguments = ["-xk", zipURL.path, downloadDir.path]

        try unzipProcess.run()
        unzipProcess.waitUntilExit()

        guard unzipProcess.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        // Clear quarantine attribute using xattr
        let xattrProcess = Process()
        xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProcess.arguments = ["-cr", extractedAppURL.path]

        try xattrProcess.run()
        xattrProcess.waitUntilExit()

        // Reveal in Finder
        NSWorkspace.shared.selectFile(extractedAppURL.path, inFileViewerRootedAtPath: downloadDir.path)
    }

    /// Open the GitHub release page in browser
    func openReleasePage() {
        guard let release = latestRelease,
              let url = URL(string: release.htmlUrl) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Skip the current available version
    func skipVersion() {
        guard let release = latestRelease else { return }
        UserDefaults.standard.set(release.tagName, forKey: skippedVersionKey)
        updateAvailable = false
    }

    /// Check if a version has been skipped
    func isVersionSkipped(_ version: String) -> Bool {
        UserDefaults.standard.string(forKey: skippedVersionKey) == version
    }

    /// Clear skipped version (useful when user manually checks for updates)
    func clearSkippedVersion() {
        UserDefaults.standard.removeObject(forKey: skippedVersionKey)
    }

    // MARK: - Private Methods

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: githubAPIURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageTracker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw UpdateError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private func downloadWithProgress(from url: URL, expectedSize: Int) async throws -> (URL, URLResponse) {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        var downloadedData = Data()
        downloadedData.reserveCapacity(expectedSize)

        for try await byte in asyncBytes {
            downloadedData.append(byte)

            // Update progress on main thread periodically
            if downloadedData.count % 10240 == 0 { // Every 10KB
                let progress = Double(downloadedData.count) / Double(expectedSize)
                downloadProgress = min(progress, 0.99)
            }
        }

        try downloadedData.write(to: tempURL)
        return (tempURL, response)
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case noAssetFound
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case unzipFailed
    case installFailed

    var errorDescription: String? {
        switch self {
        case .noAssetFound:
            return "No downloadable asset found in release"
        case .invalidURL:
            return "Invalid download URL"
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .unzipFailed:
            return "Failed to extract update"
        case .installFailed:
            return "Failed to install update"
        }
    }
}
