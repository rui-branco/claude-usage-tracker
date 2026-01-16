import Foundation

/// Cached data for a project directory (aggregated from all transcript files)
struct CachedDirectoryData: Codable {
    /// Latest modification time of any file in directory
    let latestFileModification: Date
    /// Number of files when cached (detect new files)
    let fileCount: Int
    /// Month key for monthly data (YYYY-MM)
    let monthKey: String

    // Aggregated usage data
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let isBedrock: Bool
    let isClaudeAPI: Bool
    let calculatedCost: Double
    let monthlyInputTokens: Int
    let monthlyOutputTokens: Int
    let monthlyCacheCreationTokens: Int
    let monthlyCacheReadTokens: Int
    let calculatedMonthlyCost: Double
    let modelUsage: [String: CachedModelUsage]
    let monthlyModelUsage: [String: CachedModelUsage]
}

struct CachedModelUsage: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
}

/// Cache for all project directories
struct TranscriptCache: Codable {
    var version: Int = 2
    /// Map of directory path -> cached data
    var directories: [String: CachedDirectoryData] = [:]
    var lastUpdated: Date = Date()
}

/// Service that manages transcript caching for efficient parsing
final class TranscriptCacheService: @unchecked Sendable {
    static let shared = TranscriptCacheService()

    private let cacheFilePath: String
    private var cache: TranscriptCache
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        cacheFilePath = "\(homeDir)/.claude/usage-tracker-transcript-cache.json"
        cache = TranscriptCache()
        loadCache()
    }

    // MARK: - Cache Persistence

    private func loadCache() {
        guard let data = fileManager.contents(atPath: cacheFilePath),
              let loaded = try? JSONDecoder().decode(TranscriptCache.self, from: data),
              loaded.version == 2 else {
            return
        }
        cache = loaded
    }

    func saveCache() {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: URL(fileURLWithPath: cacheFilePath))
        }
    }

    // MARK: - Cache Lookup

    /// Get current month key for tracking monthly stats
    func currentMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    /// Get directory info: latest file modification and file count
    private func getDirectoryInfo(_ directory: String) -> (latestMod: Date, fileCount: Int)? {
        guard let files = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }
        var latestMod = Date.distantPast

        for file in jsonlFiles {
            let fullPath = "\(directory)/\(file)"
            if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
               let modDate = attrs[.modificationDate] as? Date {
                if modDate > latestMod {
                    latestMod = modDate
                }
            }
        }

        return (latestMod, jsonlFiles.count)
    }

    /// Check if a directory needs re-parsing
    func needsParsing(directory: String) -> Bool {
        guard let cached = cache.directories[directory] else {
            return true // Not in cache
        }

        // Re-parse if month changed (monthly stats need recalculation)
        if cached.monthKey != currentMonthKey() {
            return true
        }

        // Get current directory state
        guard let info = getDirectoryInfo(directory) else {
            return true
        }

        // Re-parse if new files added
        if info.fileCount != cached.fileCount {
            return true
        }

        // Re-parse if any file was modified
        if info.latestMod > cached.latestFileModification {
            return true
        }

        return false
    }

    /// Get cached data for a directory (nil if not cached or stale)
    func getCached(directory: String) -> CachedDirectoryData? {
        guard !needsParsing(directory: directory) else {
            return nil
        }
        return cache.directories[directory]
    }

    /// Store parsed data for a directory
    func cacheDirectory(directory: String, usage: TranscriptUsage) {
        guard let info = getDirectoryInfo(directory) else {
            return
        }

        let cached = CachedDirectoryData(
            latestFileModification: info.latestMod,
            fileCount: info.fileCount,
            monthKey: currentMonthKey(),
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens,
            isBedrock: usage.isBedrock,
            isClaudeAPI: usage.isClaudeAPI,
            calculatedCost: usage.calculatedCost,
            monthlyInputTokens: usage.monthlyInputTokens,
            monthlyOutputTokens: usage.monthlyOutputTokens,
            monthlyCacheCreationTokens: usage.monthlyCacheCreationTokens,
            monthlyCacheReadTokens: usage.monthlyCacheReadTokens,
            calculatedMonthlyCost: usage.calculatedMonthlyCost,
            modelUsage: usage.modelUsage.mapValues { m in
                CachedModelUsage(
                    inputTokens: m.inputTokens,
                    outputTokens: m.outputTokens,
                    cacheCreationTokens: m.cacheCreationTokens,
                    cacheReadTokens: m.cacheReadTokens
                )
            },
            monthlyModelUsage: usage.monthlyModelUsage.mapValues { m in
                CachedModelUsage(
                    inputTokens: m.inputTokens,
                    outputTokens: m.outputTokens,
                    cacheCreationTokens: m.cacheCreationTokens,
                    cacheReadTokens: m.cacheReadTokens
                )
            }
        )

        lock.lock()
        cache.directories[directory] = cached
        cache.lastUpdated = Date()
        lock.unlock()
    }

    /// Remove stale entries for directories that no longer exist
    func cleanupStaleEntries() {
        lock.lock()
        let staleKeys = cache.directories.keys.filter { !fileManager.fileExists(atPath: $0) }
        for key in staleKeys {
            cache.directories.removeValue(forKey: key)
        }
        lock.unlock()
        if !staleKeys.isEmpty {
            saveCache()
        }
    }

    /// Convert cached data back to TranscriptUsage
    func toTranscriptUsage(_ cached: CachedDirectoryData) -> TranscriptUsage {
        var usage = TranscriptUsage()
        usage.inputTokens = cached.inputTokens
        usage.outputTokens = cached.outputTokens
        usage.cacheCreationTokens = cached.cacheCreationTokens
        usage.cacheReadTokens = cached.cacheReadTokens
        usage.isBedrock = cached.isBedrock
        usage.isClaudeAPI = cached.isClaudeAPI
        usage.calculatedCost = cached.calculatedCost
        usage.monthlyInputTokens = cached.monthlyInputTokens
        usage.monthlyOutputTokens = cached.monthlyOutputTokens
        usage.monthlyCacheCreationTokens = cached.monthlyCacheCreationTokens
        usage.monthlyCacheReadTokens = cached.monthlyCacheReadTokens
        usage.calculatedMonthlyCost = cached.calculatedMonthlyCost
        usage.modelUsage = cached.modelUsage.mapValues { m in
            var data = ModelUsageData()
            data.inputTokens = m.inputTokens
            data.outputTokens = m.outputTokens
            data.cacheCreationTokens = m.cacheCreationTokens
            data.cacheReadTokens = m.cacheReadTokens
            return data
        }
        usage.monthlyModelUsage = cached.monthlyModelUsage.mapValues { m in
            var data = ModelUsageData()
            data.inputTokens = m.inputTokens
            data.outputTokens = m.outputTokens
            data.cacheCreationTokens = m.cacheCreationTokens
            data.cacheReadTokens = m.cacheReadTokens
            return data
        }
        return usage
    }
}
