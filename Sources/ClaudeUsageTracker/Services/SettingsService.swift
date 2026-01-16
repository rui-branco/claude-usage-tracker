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
    @Published var showRecentProjects: Bool {
        didSet { UserDefaults.standard.set(showRecentProjects, forKey: "showRecentProjects") }
    }
    @Published var showAllTimeStats: Bool {
        didSet { UserDefaults.standard.set(showAllTimeStats, forKey: "showAllTimeStats") }
    }

    // MARK: - Display Settings
    @Published var showMenuBarPercentage: Bool {
        didSet { UserDefaults.standard.set(showMenuBarPercentage, forKey: "showMenuBarPercentage") }
    }
    @Published var showMenuBarAPICost: Bool {
        didSet { UserDefaults.standard.set(showMenuBarAPICost, forKey: "showMenuBarAPICost") }
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
    @Published var dailyCostAlertEnabled: Bool {
        didSet { UserDefaults.standard.set(dailyCostAlertEnabled, forKey: "dailyCostAlertEnabled") }
    }
    @Published var dailyCostAlertThreshold: Double {
        didSet { UserDefaults.standard.set(dailyCostAlertThreshold, forKey: "dailyCostAlertThreshold") }
    }
    @Published var monthlyCostAlertEnabled: Bool {
        didSet { UserDefaults.standard.set(monthlyCostAlertEnabled, forKey: "monthlyCostAlertEnabled") }
    }
    @Published var monthlyCostAlertThreshold: Double {
        didSet { UserDefaults.standard.set(monthlyCostAlertThreshold, forKey: "monthlyCostAlertThreshold") }
    }

    // MARK: - Data Settings
    @Published var cacheRetentionDays: Int {
        didSet { UserDefaults.standard.set(cacheRetentionDays, forKey: "cacheRetentionDays") }
    }
    @Published var enableAnalytics: Bool {
        didSet { UserDefaults.standard.set(enableAnalytics, forKey: "enableAnalytics") }
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
            "showRecentProjects": true,
            "showAllTimeStats": true,
            // Display
            "showMenuBarPercentage": true,
            "showMenuBarAPICost": true,
            "compactMode": false,
            "showTokenCounts": true,
            // Notifications
            "notificationsEnabled": true,
            "rateLimitWarningThreshold": 80,
            "dailyCostAlertEnabled": false,
            "dailyCostAlertThreshold": 10.0,
            "monthlyCostAlertEnabled": false,
            "monthlyCostAlertThreshold": 100.0,
            // Data
            "cacheRetentionDays": 90,
            "enableAnalytics": true
        ])

        // Load values
        self.autoRefreshEnabled = defaults.bool(forKey: "autoRefreshEnabled")
        self.refreshInterval = defaults.integer(forKey: "refreshInterval")
        self.defaultTimeFrame = defaults.string(forKey: "defaultTimeFrame") ?? "7D"

        self.showLiveSessions = defaults.bool(forKey: "showLiveSessions")
        self.showRateLimits = defaults.bool(forKey: "showRateLimits")
        self.showTrendChart = defaults.bool(forKey: "showTrendChart")
        self.showModelBreakdown = defaults.bool(forKey: "showModelBreakdown")
        self.showRecentProjects = defaults.bool(forKey: "showRecentProjects")
        self.showAllTimeStats = defaults.bool(forKey: "showAllTimeStats")

        self.showMenuBarPercentage = defaults.bool(forKey: "showMenuBarPercentage")
        self.showMenuBarAPICost = defaults.bool(forKey: "showMenuBarAPICost")
        self.compactMode = defaults.bool(forKey: "compactMode")
        self.showTokenCounts = defaults.bool(forKey: "showTokenCounts")

        self.notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        self.rateLimitWarningThreshold = defaults.integer(forKey: "rateLimitWarningThreshold")
        self.dailyCostAlertEnabled = defaults.bool(forKey: "dailyCostAlertEnabled")
        self.dailyCostAlertThreshold = defaults.double(forKey: "dailyCostAlertThreshold")
        self.monthlyCostAlertEnabled = defaults.bool(forKey: "monthlyCostAlertEnabled")
        self.monthlyCostAlertThreshold = defaults.double(forKey: "monthlyCostAlertThreshold")

        self.cacheRetentionDays = defaults.integer(forKey: "cacheRetentionDays")
        self.enableAnalytics = defaults.bool(forKey: "enableAnalytics")
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
        showRecentProjects = true
        showAllTimeStats = true
        showMenuBarPercentage = true
        showMenuBarAPICost = true
        compactMode = false
        showTokenCounts = true
        notificationsEnabled = true
        rateLimitWarningThreshold = 80
        dailyCostAlertEnabled = false
        dailyCostAlertThreshold = 10.0
        monthlyCostAlertEnabled = false
        monthlyCostAlertThreshold = 100.0
        cacheRetentionDays = 90
        enableAnalytics = true
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
