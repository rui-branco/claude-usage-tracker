import Foundation
import Combine

@MainActor
final class SettingsService: ObservableObject {
    // MARK: - General Settings
    @Published var autoRefreshEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRefreshEnabled, forKey: "autoRefreshEnabled") }
    }
    @Published var refreshInterval: Int {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }
    @Published var defaultTimeFrame: String {
        didSet { UserDefaults.standard.set(defaultTimeFrame, forKey: "defaultTimeFrame") }
    }

    // MARK: - Visibility Settings
    @Published var showLiveSessions: Bool {
        didSet { UserDefaults.standard.set(showLiveSessions, forKey: "showLiveSessions") }
    }
    @Published var showRateLimits: Bool {
        didSet { UserDefaults.standard.set(showRateLimits, forKey: "showRateLimits") }
    }
    @Published var showTrendChart: Bool {
        didSet { UserDefaults.standard.set(showTrendChart, forKey: "showTrendChart") }
    }
    @Published var showModelBreakdown: Bool {
        didSet { UserDefaults.standard.set(showModelBreakdown, forKey: "showModelBreakdown") }
    }
    @Published var showAllTimeStats: Bool {
        didSet { UserDefaults.standard.set(showAllTimeStats, forKey: "showAllTimeStats") }
    }

    // MARK: - Display Settings
    @Published var showMenuBarPercentage: Bool {
        didSet { UserDefaults.standard.set(showMenuBarPercentage, forKey: "showMenuBarPercentage") }
    }
    @Published var compactMode: Bool {
        didSet { UserDefaults.standard.set(compactMode, forKey: "compactMode") }
    }
    @Published var showTokenCounts: Bool {
        didSet { UserDefaults.standard.set(showTokenCounts, forKey: "showTokenCounts") }
    }

    // MARK: - Notification Settings
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var rateLimitWarningThreshold: Int {
        didSet { UserDefaults.standard.set(rateLimitWarningThreshold, forKey: "rateLimitWarningThreshold") }
    }

    // MARK: - Data Settings
    @Published var cacheRetentionDays: Int {
        didSet { UserDefaults.standard.set(cacheRetentionDays, forKey: "cacheRetentionDays") }
    }
    @Published var enableAnalytics: Bool {
        didSet { UserDefaults.standard.set(enableAnalytics, forKey: "enableAnalytics") }
    }

    // MARK: - Update Settings
    @Published var checkForUpdatesAutomatically: Bool {
        didSet { UserDefaults.standard.set(checkForUpdatesAutomatically, forKey: "checkForUpdatesAutomatically") }
    }
    @Published var lastUpdateCheck: Date? {
        didSet { UserDefaults.standard.set(lastUpdateCheck, forKey: "lastUpdateCheck") }
    }

    static let shared = SettingsService()

    init() {
        let defaults = UserDefaults.standard

        // Register defaults
        defaults.register(defaults: [
            // General
            "autoRefreshEnabled": true,
            "refreshInterval": 5,
            "defaultTimeFrame": "7D",
            // Visibility
            "showLiveSessions": true,
            "showRateLimits": true,
            "showTrendChart": true,
            "showModelBreakdown": true,
            "showAllTimeStats": true,
            // Display
            "showMenuBarPercentage": true,
            "compactMode": false,
            "showTokenCounts": true,
            // Notifications
            "notificationsEnabled": true,
            "rateLimitWarningThreshold": 80,
            // Data
            "cacheRetentionDays": 90,
            "enableAnalytics": true,
            // Updates
            "checkForUpdatesAutomatically": true
        ])

        // Load values
        self.autoRefreshEnabled = defaults.bool(forKey: "autoRefreshEnabled")
        self.refreshInterval = defaults.integer(forKey: "refreshInterval")
        self.defaultTimeFrame = defaults.string(forKey: "defaultTimeFrame") ?? "7D"

        self.showLiveSessions = defaults.bool(forKey: "showLiveSessions")
        self.showRateLimits = defaults.bool(forKey: "showRateLimits")
        self.showTrendChart = defaults.bool(forKey: "showTrendChart")
        self.showModelBreakdown = defaults.bool(forKey: "showModelBreakdown")
        self.showAllTimeStats = defaults.bool(forKey: "showAllTimeStats")

        self.showMenuBarPercentage = defaults.bool(forKey: "showMenuBarPercentage")
        self.compactMode = defaults.bool(forKey: "compactMode")
        self.showTokenCounts = defaults.bool(forKey: "showTokenCounts")

        self.notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        self.rateLimitWarningThreshold = defaults.integer(forKey: "rateLimitWarningThreshold")

        self.cacheRetentionDays = defaults.integer(forKey: "cacheRetentionDays")
        self.enableAnalytics = defaults.bool(forKey: "enableAnalytics")

        self.checkForUpdatesAutomatically = defaults.bool(forKey: "checkForUpdatesAutomatically")
        self.lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
    }

    // MARK: - Cache Management

    func clearCache() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let cachePath = "\(homeDir)/.claude/usage-tracker-cache.json"

        do {
            try FileManager.default.removeItem(atPath: cachePath)
        } catch {
            print("Failed to clear cache: \(error)")
        }
    }

    func getCacheSize() -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let cachePath = "\(homeDir)/.claude/usage-tracker-cache.json"

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath),
              let size = attributes[.size] as? Int64 else {
            return "0 KB"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    func resetAllSettings() {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? "com.ruibranco.ClaudeUsageTracker"
        defaults.removePersistentDomain(forName: domain)

        // Reload defaults
        autoRefreshEnabled = true
        refreshInterval = 5
        defaultTimeFrame = "7D"
        showLiveSessions = true
        showRateLimits = true
        showTrendChart = true
        showModelBreakdown = true
        showAllTimeStats = true
        showMenuBarPercentage = true
        compactMode = false
        showTokenCounts = true
        notificationsEnabled = true
        rateLimitWarningThreshold = 80
        cacheRetentionDays = 90
        enableAnalytics = true
        checkForUpdatesAutomatically = true
        lastUpdateCheck = nil
    }
}

// Refresh intervals in seconds
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case fast = 3
    case normal = 5
    case slow = 10
    case verySlow = 30

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .fast: return "3 sec"
        case .normal: return "5 sec"
        case .slow: return "10 sec"
        case .verySlow: return "30 sec"
        }
    }
}
