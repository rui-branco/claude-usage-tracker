import Foundation
import Combine

@MainActor
final class FileWatcherService: ObservableObject {
    @Published var statsCache: StatsCache?
    @Published var claudeConfig: ClaudeConfig?
    @Published var rateLimitCache: RateLimitCache?
    @Published var sessionCache: SessionCache?
    @Published var lastError: String?

    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private let fileManager = FileManager.default

    private let statsCachePath: String
    private let claudeConfigPath: String
    private let rateLimitPath: String
    private let sessionCachePath: String

    init() {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        statsCachePath = "\(homeDir)/.claude/stats-cache.json"
        claudeConfigPath = "\(homeDir)/.claude.json"
        rateLimitPath = "\(homeDir)/.claude/plugins/claude-hud/.usage-cache.json"
        sessionCachePath = "\(homeDir)/.claude/plugins/claude-hud/.session-cache.json"

        // Don't load/watch in init - call start() manually later
    }

    func start() {
        loadAllFiles()
        setupWatchers()
    }

    private func setupWatchers() {
        watchFile(at: statsCachePath) { [weak self] in
            Task { @MainActor in
                self?.loadStatsCache()
            }
        }
        watchFile(at: claudeConfigPath) { [weak self] in
            Task { @MainActor in
                self?.loadClaudeConfig()
            }
        }
        watchFile(at: rateLimitPath) { [weak self] in
            Task { @MainActor in
                self?.loadRateLimitCache()
            }
        }
        watchFile(at: sessionCachePath) { [weak self] in
            Task { @MainActor in
                self?.loadSessionCache()
            }
        }
    }

    private func watchFile(at path: String, onChange: @escaping () -> Void) {
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            lastError = "Cannot watch \(path)"
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: .main
        )

        source.setEventHandler { onChange() }
        source.setCancelHandler { close(fileDescriptor) }
        source.resume()

        fileWatchers[path] = source
    }

    private func loadStatsCache() {
        guard let data = fileManager.contents(atPath: statsCachePath) else {
            lastError = "Cannot read stats-cache.json"
            return
        }
        do {
            statsCache = try JSONDecoder().decode(StatsCache.self, from: data)
        } catch {
            lastError = "Parse error: \(error.localizedDescription)"
        }
    }

    private func loadClaudeConfig() {
        guard let data = fileManager.contents(atPath: claudeConfigPath) else {
            lastError = "Cannot read .claude.json"
            return
        }
        do {
            claudeConfig = try JSONDecoder().decode(ClaudeConfig.self, from: data)
        } catch {
            lastError = "Parse error: \(error.localizedDescription)"
        }
    }

    private func loadRateLimitCache() {
        guard let data = fileManager.contents(atPath: rateLimitPath) else {
            // Rate limit cache might not exist
            return
        }
        do {
            rateLimitCache = try JSONDecoder().decode(RateLimitCache.self, from: data)
        } catch {
            lastError = "Parse error: \(error.localizedDescription)"
        }
    }

    private func loadSessionCache() {
        guard let data = fileManager.contents(atPath: sessionCachePath) else {
            NSLog("[DEBUG] Session cache file not found at: %@", sessionCachePath)
            return
        }
        do {
            sessionCache = try JSONDecoder().decode(SessionCache.self, from: data)
            NSLog("[DEBUG] Session cache loaded: context=%d%%", Int(sessionCache?.contextWindow?.usedPercentage ?? -1))
        } catch {
            lastError = "Parse error: \(error.localizedDescription)"
            NSLog("[DEBUG] Session cache parse error: %@", error.localizedDescription)
        }
    }

    func loadAllFiles() {
        loadStatsCache()
        loadClaudeConfig()
        loadRateLimitCache()
        loadSessionCache()
    }

    func refresh() {
        loadAllFiles()
    }

    deinit {
        fileWatchers.values.forEach { $0.cancel() }
    }
}
