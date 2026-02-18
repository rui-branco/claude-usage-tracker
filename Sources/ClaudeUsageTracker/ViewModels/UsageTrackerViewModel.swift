import Foundation
import Combine
import SwiftUI

enum TimeFrame: String, CaseIterable, Identifiable {
    case day = "1D"
    case week = "7D"
    case month = "1M"
    case threeMonths = "3M"
    case all = "All"

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .threeMonths: return 90
        case .all: return nil
        }
    }

    var displayName: String {
        switch self {
        case .day: return "Today"
        case .week: return "7 Days"
        case .month: return "Month"
        case .threeMonths: return "3 Months"
        case .all: return "All Time"
        }
    }
}

@MainActor
final class UsageTrackerViewModel: ObservableObject {
    @Published var statsCache: StatsCache?
    @Published var claudeConfig: ClaudeConfig?
    @Published var rateLimitStatus: RateLimitStatus?
    @Published var lastUpdated: Date?
    @Published var isLoading = false
    @Published var selectedTimeFrame: TimeFrame = .week

    // Live sessions from process monitor
    @Published var liveClaudeSessions: [LiveClaudeSession] = []
    @Published var isLoadingSessions = true
    @Published var sessionCache: SessionCache?

    // UI State
    @Published var showDetails = false
    @Published var isModelsExpanded = true
    @Published var isTrendExpanded = true

    private let fileWatcher: FileWatcherService
    private let processMonitor: ProcessMonitorService
    private var cancellables = Set<AnyCancellable>()

    init(fileWatcher: FileWatcherService, processMonitor: ProcessMonitorService) {
        self.fileWatcher = fileWatcher
        self.processMonitor = processMonitor

        setupBindings()

        // Fetch rate limit usage from API
        fetchUsageFromAPI()

        // Set up periodic refresh of usage data (every 60 seconds)
        setupUsageRefreshTimer()
    }

    private var usageRefreshTimer: Timer?

    private func setupUsageRefreshTimer() {
        usageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchUsageFromAPI()
            }
        }
    }

    private func fetchUsageFromAPI() {
        Task {
            do {
                let usage = try await UsageAPIService.shared.fetchUsage()
                updateRateLimitFromAPI(usage)
            } catch {
                NSLog("[UsageAPI] Failed to fetch: %@", error.localizedDescription)
            }
        }
    }

    private func updateRateLimitFromAPI(_ usage: UsageAPIService.UsageResponse) {
        let fiveHourPercent = Int(min(max(usage.fiveHour.utilization, 0), 100))
        let sevenDayPercent = Int(min(max(usage.sevenDay.utilization, 0), 100))

        let data = RateLimitData(
            planName: "Max",
            fiveHour: fiveHourPercent,
            sevenDay: sevenDayPercent,
            fiveHourResetAt: usage.fiveHour.resetsAt,
            sevenDayResetAt: usage.sevenDay.resetsAt
        )
        let cache = RateLimitCache(
            data: data,
            timestamp: Int(Date().timeIntervalSince1970)
        )

        updateRateLimitStatus(from: cache)
    }

    private func setupBindings() {
        fileWatcher.$statsCache
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                self?.statsCache = stats
                self?.lastUpdated = Date()
            }
            .store(in: &cancellables)

        fileWatcher.$claudeConfig
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.claudeConfig = config
                self?.refreshEnrichedSessions()
            }
            .store(in: &cancellables)

        fileWatcher.$rateLimitCache
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cache in
                self?.updateRateLimitStatus(from: cache)
            }
            .store(in: &cancellables)

        processMonitor.$liveSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.rawLiveSessions = sessions
                self?.refreshEnrichedSessions()
            }
            .store(in: &cancellables)

        processMonitor.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                self?.isLoadingSessions = loading
            }
            .store(in: &cancellables)

        fileWatcher.$sessionCache
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cache in
                self?.sessionCache = cache
                self?.refreshEnrichedSessions()
            }
            .store(in: &cancellables)
    }

    private var rawLiveSessions: [LiveClaudeSession] = []

    private func refreshEnrichedSessions() {
        liveClaudeSessions = enrichSessionsWithUsageData(rawLiveSessions)
    }

    private func enrichSessionsWithUsageData(_ sessions: [LiveClaudeSession]) -> [LiveClaudeSession] {
        let projects = claudeConfig?.projects
        var enrichedSessions = sessions

        // Apply real-time data from session cache if we can match
        if let cache = sessionCache, let cwd = cache.cwd {
            let cachePath = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cacheProjectName = URL(fileURLWithPath: cwd).lastPathComponent

            for i in 0..<enrichedSessions.count {
                let sessionPath = enrichedSessions[i].projectPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let isMatch = cachePath == sessionPath ||
                              cacheProjectName == enrichedSessions[i].projectName ||
                              sessionPath.hasSuffix(cacheProjectName) ||
                              cachePath.hasSuffix(enrichedSessions[i].projectName)

                if isMatch, let contextWindow = cache.contextWindow {
                    enrichedSessions[i].tokens = contextWindow.totalTokens
                    enrichedSessions[i].contextPercent = contextWindow.usedPercentage
                    enrichedSessions[i].isRealtime = true
                    if let model = cache.model {
                        enrichedSessions[i].modelName = model.displayName ?? model.id
                    }
                    break
                }
            }
        }

        // Enrich with config data (tokens from last session)
        for i in 0..<enrichedSessions.count {
            let sessionPath = enrichedSessions[i].projectPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            if let projects = projects {
                for (configPath, projectConfig) in projects {
                    let normalizedConfigPath = configPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if normalizedConfigPath == sessionPath {
                        let inputTokens = projectConfig.lastTotalInputTokens ?? 0
                        let outputTokens = projectConfig.lastTotalOutputTokens ?? 0
                        if enrichedSessions[i].tokens == nil {
                            enrichedSessions[i].tokens = inputTokens + outputTokens
                        }
                        break
                    }
                }
            }
        }

        return enrichedSessions
    }

    // Track previous values for burn rate calculation
    private var lastSessionPercent: Int?
    private var lastWeeklyPercent: Int?
    private var lastRateLimitUpdate: Date?

    // Smoothed burn rates (exponential moving average)
    private var smoothedSessionRate: Double = 0
    private var smoothedWeeklyRate: Double = 0

    private func updateRateLimitStatus(from cache: RateLimitCache?) {
        guard let cache = cache else {
            rateLimitStatus = nil
            MenuBarState.shared.sessionPercent = nil
            MenuBarState.shared.fiveHourResetAt = nil
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fiveHourReset = formatter.date(from: cache.data.fiveHourResetAt) ?? Date()
        let sevenDayReset = formatter.date(from: cache.data.sevenDayResetAt) ?? Date()

        // Calculate recent burn rates based on change since last update
        var recentSessionRate: Double?
        var recentWeeklyRate: Double?

        if let lastUpdate = lastRateLimitUpdate,
           let lastSession = lastSessionPercent,
           let lastWeekly = lastWeeklyPercent {

            let timeDelta = Date().timeIntervalSince(lastUpdate)

            if timeDelta >= 10 {
                let hoursDelta = timeDelta / 3600.0

                let sessionDelta = cache.data.fiveHour - lastSession
                if sessionDelta > 0 {
                    let instantRate = Double(sessionDelta) / hoursDelta
                    smoothedSessionRate = 0.7 * instantRate + 0.3 * smoothedSessionRate
                    recentSessionRate = smoothedSessionRate
                } else if sessionDelta < 0 {
                    smoothedSessionRate = 0
                }

                let weeklyDelta = cache.data.sevenDay - lastWeekly
                if weeklyDelta > 0 {
                    let instantRate = Double(weeklyDelta) / hoursDelta
                    smoothedWeeklyRate = 0.7 * instantRate + 0.3 * smoothedWeeklyRate
                    recentWeeklyRate = smoothedWeeklyRate
                } else if weeklyDelta < 0 {
                    smoothedWeeklyRate = 0
                }
            }
        }

        lastSessionPercent = cache.data.fiveHour
        lastWeeklyPercent = cache.data.sevenDay
        lastRateLimitUpdate = Date()

        var status = RateLimitStatus(
            planName: cache.data.planName,
            fiveHourUsed: cache.data.fiveHour,
            sevenDayUsed: cache.data.sevenDay,
            fiveHourResetAt: fiveHourReset,
            sevenDayResetAt: sevenDayReset
        )

        status.recentSessionBurnRate = recentSessionRate ?? smoothedSessionRate
        status.recentWeeklyBurnRate = recentWeeklyRate ?? smoothedWeeklyRate

        rateLimitStatus = status

        MenuBarState.shared.sessionPercent = cache.data.fiveHour
        MenuBarState.shared.fiveHourResetAt = fiveHourReset
    }

    func refresh() {
        isLoading = true
        fileWatcher.refresh()
        fetchUsageFromAPI()
        UsageAPIService.shared.clearCache()
        isLoading = false
    }

    func killSession(_ session: LiveClaudeSession) {
        processMonitor.killSession(session)
    }

    func killOrphanedSessions() {
        processMonitor.killOrphanedSessions()
    }

    var orphanedSessionCount: Int {
        liveClaudeSessions.filter { $0.isOrphaned }.count
    }

    var orphanedMemoryMB: Int {
        liveClaudeSessions.filter { $0.isOrphaned }.reduce(0) { $0 + $1.memoryMB }
    }

    var liveSessionCount: Int {
        liveClaudeSessions.count
    }

    // MARK: - Time Frame Filtered Data

    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }

    private func isDateInTimeFrame(_ dateStr: String) -> Bool {
        guard let days = selectedTimeFrame.days else { return true }
        guard let date = dateFormatter.date(from: dateStr) else { return false }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return date >= cutoff
    }

    var filteredActivity: [DailyActivity] {
        guard let stats = statsCache else { return [] }
        return stats.dailyActivity.filter { isDateInTimeFrame($0.date) }
    }

    var filteredTokenData: [DailyModelTokens] {
        guard let stats = statsCache else { return [] }
        return stats.dailyModelTokens.filter { isDateInTimeFrame($0.date) }
    }

    var periodMessages: Int {
        filteredActivity.reduce(0) { $0 + $1.messageCount }
    }

    var periodSessions: Int {
        filteredActivity.reduce(0) { $0 + $1.sessionCount }
    }

    var periodToolCalls: Int {
        filteredActivity.reduce(0) { $0 + $1.toolCallCount }
    }

    var periodTokens: Int {
        filteredTokenData.reduce(0) { sum, day in
            sum + day.tokensByModel.values.reduce(0, +)
        }
    }

    var periodTokensByModel: [(name: String, displayName: String, tokens: Int, color: Color)] {
        guard let usage = statsCache?.modelUsage else { return [] }

        return usage.compactMap { (model, stats) in
            let totalTokens = stats.inputTokens + stats.outputTokens + stats.cacheReadInputTokens + stats.cacheCreationInputTokens
            guard totalTokens > 0,
                  !model.lowercased().contains("synthetic"),
                  model.lowercased().contains("claude") else { return nil }

            return (model, formatModelName(model), totalTokens, colorForModel(model))
        }.sorted { $0.tokens > $1.tokens }
    }

    // MARK: - All Time Stats

    var totalSessions: Int {
        statsCache?.totalSessions ?? 0
    }

    var totalMessages: Int {
        statsCache?.totalMessages ?? 0
    }

    var totalTokens: Int {
        guard let usage = statsCache?.modelUsage else { return 0 }
        return usage.values.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    // MARK: - Menu Bar Display

    var menuBarIcon: String {
        guard let rateLimit = rateLimitStatus else { return "chart.bar" }
        switch rateLimit.status {
        case .healthy: return "chart.bar.fill"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "xmark.circle.fill"
        }
    }

    var menuBarLabel: String {
        formatTokenCount(periodTokens)
    }

    var statusColor: Color {
        guard let rateLimit = rateLimitStatus else { return .gray }
        switch rateLimit.status {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: - Formatting Helpers

    private func formatModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus 4.5" }
        if model.contains("sonnet") { return "Sonnet 4.5" }
        if model.contains("haiku") { return "Haiku 4.5" }
        return model.replacingOccurrences(of: "claude-", with: "").prefix(15).description
    }

    private func colorForModel(_ model: String) -> Color {
        if model.contains("opus") { return .purple }
        if model.contains("sonnet") { return .blue }
        if model.contains("haiku") { return .green }
        return .gray
    }

    func formatTokenCount(_ count: Int) -> String {
        switch count {
        case 0..<1000: return "\(count)"
        case 1000..<1_000_000: return String(format: "%.1fK", Double(count) / 1000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}
