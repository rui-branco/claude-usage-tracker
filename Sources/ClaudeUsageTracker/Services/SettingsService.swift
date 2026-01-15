import Foundation
import Combine

@MainActor
final class SettingsService: ObservableObject {
    // Polling Settings
    @Published var autoRefreshEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRefreshEnabled, forKey: "autoRefreshEnabled") }
    }
    @Published var refreshInterval: Int {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }

    // Visibility Settings
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

    // Display Settings
    @Published var compactMode: Bool {
        didSet { UserDefaults.standard.set(compactMode, forKey: "compactMode") }
    }
    @Published var showMenuBarPercentage: Bool {
        didSet { UserDefaults.standard.set(showMenuBarPercentage, forKey: "showMenuBarPercentage") }
    }

    static let shared = SettingsService()

    init() {
        // Load from UserDefaults with defaults
        let defaults = UserDefaults.standard

        // Register defaults
        defaults.register(defaults: [
            "autoRefreshEnabled": true,
            "refreshInterval": 5,
            "showLiveSessions": true,
            "showRateLimits": true,
            "showTrendChart": true,
            "showModelBreakdown": true,
            "showRecentProjects": true,
            "showAllTimeStats": true,
            "compactMode": false,
            "showMenuBarPercentage": true
        ])

        self.autoRefreshEnabled = defaults.bool(forKey: "autoRefreshEnabled")
        self.refreshInterval = defaults.integer(forKey: "refreshInterval")
        self.showLiveSessions = defaults.bool(forKey: "showLiveSessions")
        self.showRateLimits = defaults.bool(forKey: "showRateLimits")
        self.showTrendChart = defaults.bool(forKey: "showTrendChart")
        self.showModelBreakdown = defaults.bool(forKey: "showModelBreakdown")
        self.showRecentProjects = defaults.bool(forKey: "showRecentProjects")
        self.showAllTimeStats = defaults.bool(forKey: "showAllTimeStats")
        self.compactMode = defaults.bool(forKey: "compactMode")
        self.showMenuBarPercentage = defaults.bool(forKey: "showMenuBarPercentage")
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
