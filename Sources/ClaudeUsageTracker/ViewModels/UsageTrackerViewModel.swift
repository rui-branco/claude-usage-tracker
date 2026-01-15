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

struct LiveSession: Identifiable {
    let id: String
    let projectName: String
    let projectPath: String
    let lastCost: Double
    let lastTokens: Int
    let isActive: Bool
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
    @Published var isHistoryExpanded = false
    @Published var isModelsExpanded = true
    @Published var isTrendExpanded = true

    private let fileWatcher: FileWatcherService
    private let processMonitor: ProcessMonitorService
    private var cancellables = Set<AnyCancellable>()

    init(fileWatcher: FileWatcherService, processMonitor: ProcessMonitorService) {
        self.fileWatcher = fileWatcher
        self.processMonitor = processMonitor
        setupBindings()
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
                // Re-enrich sessions when config updates
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
                // Re-enrich sessions when real-time session data updates
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

        // First: apply real-time data from session cache if we can match
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

        // Second: enrich ALL sessions with config data and calculate cost
        for i in 0..<enrichedSessions.count {
            let sessionPath = enrichedSessions[i].projectPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            if let projects = projects {
                for (configPath, projectConfig) in projects {
                    let normalizedConfigPath = configPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if normalizedConfigPath == sessionPath {
                        // Get tokens from config if not already set
                        let inputTokens = projectConfig.lastTotalInputTokens ?? 0
                        let outputTokens = projectConfig.lastTotalOutputTokens ?? 0
                        if enrichedSessions[i].tokens == nil {
                            enrichedSessions[i].tokens = inputTokens + outputTokens
                        }

                        // Check model usage and determine API type
                        if let modelUsage = projectConfig.lastModelUsage {
                            let (isBedrock, _, _) = calculateSessionCost(modelUsage: modelUsage, inputTokens: inputTokens, outputTokens: outputTokens)
                            enrichedSessions[i].isBedrock = isBedrock

                            // Use actual cost from config (lastCost) when available
                            // This contains the real cost calculated by Claude
                            if let actualCost = projectConfig.lastCost, actualCost > 0 {
                                enrichedSessions[i].cost = actualCost
                            }
                        }
                        break
                    }
                }
            }
        }

        return enrichedSessions
    }

    // Calculate cost for any session - Bedrock uses costUSD, subscription uses token pricing
    private func calculateSessionCost(modelUsage: [String: ProjectModelUsage], inputTokens: Int, outputTokens: Int) -> (isBedrock: Bool, bedrockCost: Double, subCost: Double) {
        var bedrockCost: Double = 0
        var hasBedrock = false
        var primaryModel: String = ""

        for (model, usage) in modelUsage {
            let modelLower = model.lowercased()
            let isBedrock = modelLower.contains("anthropic.claude") && !modelLower.hasPrefix("claude-")

            if isBedrock {
                hasBedrock = true
                bedrockCost += usage.costUSD ?? 0
            }
            // Track the main model for subscription pricing
            if primaryModel.isEmpty || (usage.inputTokens ?? 0) > 0 {
                primaryModel = model
            }
        }

        // Calculate subscription cost based on model and tokens
        let subCost = calculateSubscriptionCost(model: primaryModel, inputTokens: inputTokens, outputTokens: outputTokens)

        return (hasBedrock, bedrockCost, subCost)
    }

    // Calculate subscription cost using Anthropic pricing
    private func calculateSubscriptionCost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let totalTokens = Double(inputTokens + outputTokens)
        let modelLower = model.lowercased()

        // Blended rate per million tokens (accounts for typical cache usage)
        let rate: Double
        if modelLower.contains("opus-4-5") || modelLower.contains("opus-4.5") {
            rate = 24.0  // Opus 4.5
        } else if modelLower.contains("opus") {
            rate = 50.0  // Opus 3
        } else if modelLower.contains("sonnet") {
            rate = 10.0  // Sonnet
        } else if modelLower.contains("haiku") {
            rate = 1.0   // Haiku
        } else {
            rate = 10.0  // Default
        }

        return totalTokens * rate / 1_000_000
    }

    // Calculate Bedrock cost from costUSD in config
    private func calculateBedrockCost(modelUsage: [String: ProjectModelUsage]) -> (isBedrock: Bool, cost: Double) {
        var totalCost: Double = 0
        var hasBedrock = false

        for (model, usage) in modelUsage {
            let modelLower = model.lowercased()
            // Bedrock models have format like "anthropic.claude-..." or "eu.anthropic.claude-..."
            let isBedrock = modelLower.contains("anthropic.claude") && !modelLower.hasPrefix("claude-")

            if isBedrock {
                hasBedrock = true
                // Use costUSD directly from config (already calculated by Claude)
                totalCost += usage.costUSD ?? 0
            }
        }

        return (hasBedrock, totalCost)
    }

    private func updateRateLimitStatus(from cache: RateLimitCache?) {
        guard let cache = cache else {
            rateLimitStatus = nil
            MenuBarState.shared.sessionPercent = nil
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fiveHourReset = formatter.date(from: cache.data.fiveHourResetAt) ?? Date()
        let sevenDayReset = formatter.date(from: cache.data.sevenDayResetAt) ?? Date()

        rateLimitStatus = RateLimitStatus(
            planName: cache.data.planName,
            fiveHourUsed: cache.data.fiveHour,
            sevenDayUsed: cache.data.sevenDay,
            fiveHourResetAt: fiveHourReset,
            sevenDayResetAt: sevenDayReset
        )

        // Update menu bar percentage
        MenuBarState.shared.sessionPercent = cache.data.fiveHour
    }

    func refresh() {
        isLoading = true
        fileWatcher.refresh()
        isLoading = false
    }

    func killSession(_ session: LiveClaudeSession) {
        processMonitor.killSession(session)
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
        var modelTokens: [String: Int] = [:]
        for day in filteredTokenData {
            for (model, tokens) in day.tokensByModel {
                modelTokens[model, default: 0] += tokens
            }
        }
        return modelTokens.map { (model, tokens) in
            (model, formatModelName(model), tokens, colorForModel(model))
        }.sorted { $0.tokens > $1.tokens }
    }

    // MARK: - Live Sessions

    var liveSessions: [LiveSession] {
        guard let projects = claudeConfig?.projects else { return [] }
        return projects.compactMap { (path, config) in
            guard config.lastSessionId != nil else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let tokens = (config.lastTotalInputTokens ?? 0) + (config.lastTotalOutputTokens ?? 0)
            return LiveSession(
                id: config.lastSessionId ?? UUID().uuidString,
                projectName: name,
                projectPath: path,
                lastCost: config.lastCost ?? 0,
                lastTokens: tokens,
                isActive: true
            )
        }.sorted { $0.lastTokens > $1.lastTokens }
    }

    var recentSessions: [LiveSession] {
        Array(liveSessions.prefix(5))
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

    func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }
}
