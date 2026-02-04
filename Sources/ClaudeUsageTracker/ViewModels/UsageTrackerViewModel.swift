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
    var apiType: APIType = .subscription  // Only show cost for API types

    var isAPI: Bool {
        apiType != .subscription
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
    @Published var showDetails = false {
        didSet {
            if showDetails && !hasLoadedFullHistory {
                hasLoadedFullHistory = true
                updateTranscriptData(currentMonthOnly: false)
            }
        }
    }
    @Published var isHistoryExpanded = true
    @Published var isModelsExpanded = true
    @Published var isTrendExpanded = true

    private var hasLoadedFullHistory = false

    private let fileWatcher: FileWatcherService
    private let processMonitor: ProcessMonitorService
    private var cancellables = Set<AnyCancellable>()

    // Cache file path
    private let cacheFilePath: String = {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/.claude/usage-tracker-cache.json"
    }()

    init(fileWatcher: FileWatcherService, processMonitor: ProcessMonitorService) {
        self.fileWatcher = fileWatcher
        self.processMonitor = processMonitor

        // Setup bindings first so observers are ready
        setupBindings()

        // Load cached data (this will trigger the observer to update MenuBarState)
        loadFromCache()

        // Then update in background
        updateTranscriptData()

        // Fetch rate limit usage from API
        fetchUsageFromAPI()

        // Set up periodic refresh of usage data (every 60 seconds)
        setupUsageRefreshTimer()

        // Set up periodic refresh of API costs (every 30 seconds)
        setupAPICostRefreshTimer()
    }

    private var usageRefreshTimer: Timer?
    private var apiCostRefreshTimer: Timer?

    private func setupUsageRefreshTimer() {
        usageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchUsageFromAPI()
            }
        }
    }

    private func setupAPICostRefreshTimer() {
        apiCostRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateTranscriptData()
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

        // Create RateLimitCache to reuse existing logic
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

    // MARK: - Disk Cache

    private struct DiskCache: Codable {
        let sessions: [CachedSession]
        let bedrockTotal: Double
        let bedrockMonthly: Double
        let timestamp: Date

        struct CachedSession: Codable {
            let id: String
            let projectName: String
            let projectPath: String
            let lastCost: Double
            let lastTokens: Int
            let apiType: String
        }
    }

    private func loadFromCache() {
        guard let data = FileManager.default.contents(atPath: cacheFilePath),
              let cache = try? JSONDecoder().decode(DiskCache.self, from: data) else {
            return
        }

        // Load cached sessions
        cachedLiveSessions = cache.sessions.map { s in
            LiveSession(
                id: s.id,
                projectName: s.projectName,
                projectPath: s.projectPath,
                lastCost: s.lastCost,
                lastTokens: s.lastTokens,
                isActive: true,
                apiType: APIType(rawValue: s.apiType) ?? .subscription
            )
        }

        // Load cached cost breakdown (Combine observer will update MenuBarState)
        var breakdown = APICostBreakdown()
        breakdown.bedrockTotal = cache.bedrockTotal
        breakdown.bedrockMonthly = cache.bedrockMonthly
        cachedCostBreakdown = breakdown

        // Mark as loaded (not loading anymore)
        if cachedCostBreakdown.hasBedrock {
            isLoadingAPICosts = false
        }
    }

    private func saveToCache() {
        let cache = DiskCache(
            sessions: cachedLiveSessions.map { s in
                DiskCache.CachedSession(
                    id: s.id,
                    projectName: s.projectName,
                    projectPath: s.projectPath,
                    lastCost: s.lastCost,
                    lastTokens: s.lastTokens,
                    apiType: s.apiType.rawValue
                )
            },
            bedrockTotal: cachedCostBreakdown.bedrockTotal,
            bedrockMonthly: cachedCostBreakdown.bedrockMonthly,
            timestamp: Date()
        )

        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: URL(fileURLWithPath: cacheFilePath))
        }
    }

    private func setupBindings() {
        // Sync cachedCostBreakdown to MenuBarState whenever it changes
        $cachedCostBreakdown
            .receive(on: DispatchQueue.main)
            .sink { breakdown in
                let monthlyCost = breakdown.totalMonthly
                let dailyCost = breakdown.totalDaily
                if monthlyCost > 0 || dailyCost > 0 {
                    MenuBarState.shared.apiCost = monthlyCost
                    MenuBarState.shared.dailyApiCost = dailyCost
                    if breakdown.hasMultiple {
                        MenuBarState.shared.apiType = .mixed
                    } else if breakdown.hasBedrock {
                        MenuBarState.shared.apiType = .bedrock
                    } else if breakdown.hasClaudeAPI {
                        MenuBarState.shared.apiType = .claudeAPI
                    } else {
                        MenuBarState.shared.apiType = .unknown
                    }
                } else {
                    MenuBarState.shared.apiCost = nil
                    MenuBarState.shared.dailyApiCost = nil
                    MenuBarState.shared.apiType = .none
                }
            }
            .store(in: &cancellables)

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
                // Update transcript data (costs + live sessions) in background
                self?.updateTranscriptData()
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
                    // Calculate session cost from real-time token data
                    if let currentUsage = contextWindow.currentUsage {
                        let modelId = cache.model?.id ?? ""
                        let sessionCost = PricingService.shared.calculateCost(
                            inputTokens: currentUsage.inputTokens ?? 0,
                            outputTokens: currentUsage.outputTokens ?? 0,
                            cacheCreationTokens: currentUsage.cacheCreationInputTokens ?? 0,
                            cacheReadTokens: currentUsage.cacheReadInputTokens ?? 0,
                            model: modelId
                        )
                        if sessionCost > 0 {
                            enrichedSessions[i].cost = sessionCost
                        }
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
                            let (isBedrockModel, _, _) = calculateSessionCost(modelUsage: modelUsage, inputTokens: inputTokens, outputTokens: outputTokens)
                            if isBedrockModel {
                                enrichedSessions[i].apiType = .bedrock
                            }
                            // Note: Don't set cost from config here - we want session-specific cost
                            // which comes from real-time data in the first pass
                        }
                        break
                    }
                }
            }
        }

        // Third: use API type from cached live sessions, but DON'T override session-specific cost
        // Session cost should come from real-time data (first pass), not project totals
        for i in 0..<enrichedSessions.count {
            let sessionName = enrichedSessions[i].projectName
            let sessionPath = enrichedSessions[i].projectPath

            // Try to match with cached session by name or path
            if let cachedSession = cachedLiveSessions.first(where: { cached in
                cached.projectName == sessionName ||
                cached.projectPath.contains(sessionName) ||
                sessionPath.contains(cached.projectName)
            }) {
                // Only use API type, not cost (cost should be session-specific from real-time data)
                if cachedSession.isAPI {
                    enrichedSessions[i].apiType = cachedSession.apiType
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

            // Only calculate if at least 10 seconds have passed
            if timeDelta >= 10 {
                let hoursDelta = timeDelta / 3600.0

                // Session rate: detect if we're in a new window (reset happened)
                let sessionDelta = cache.data.fiveHour - lastSession
                if sessionDelta > 0 {
                    let instantRate = Double(sessionDelta) / hoursDelta
                    // Exponential smoothing: 70% new, 30% old (reacts fast to spikes)
                    smoothedSessionRate = 0.7 * instantRate + 0.3 * smoothedSessionRate
                    recentSessionRate = smoothedSessionRate
                } else if sessionDelta < 0 {
                    // Reset happened, clear the rate
                    smoothedSessionRate = 0
                }

                // Weekly rate
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

        // Update tracking values
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

        // Pass the recent burn rates
        status.recentSessionBurnRate = recentSessionRate ?? smoothedSessionRate
        status.recentWeeklyBurnRate = recentWeeklyRate ?? smoothedWeeklyRate

        rateLimitStatus = status

        // Update menu bar percentage and reset date
        MenuBarState.shared.sessionPercent = cache.data.fiveHour
        MenuBarState.shared.fiveHourResetAt = fiveHourReset
    }

    func refresh() {
        isLoading = true
        fileWatcher.refresh()
        fetchUsageFromAPI()
        UsageAPIService.shared.clearCache()  // Force fresh fetch
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

    var periodTokensByModel: [(name: String, displayName: String, tokens: Int, color: Color, apiCost: Double)] {
        // Use statsCache.modelUsage - already has accurate token breakdown, loads instantly
        guard let usage = statsCache?.modelUsage else { return [] }

        return usage.compactMap { (model, stats) in
            // Filter out synthetic/unknown models and models with 0 tokens
            let totalTokens = stats.inputTokens + stats.outputTokens + stats.cacheReadInputTokens + stats.cacheCreationInputTokens
            guard totalTokens > 0,
                  !model.lowercased().contains("synthetic"),
                  model.lowercased().contains("claude") else { return nil }

            let apiCost = calculateAPIPrice(model: model, stats: stats)
            return (model, formatModelName(model), totalTokens, colorForModel(model), apiCost)
        }.sorted { $0.tokens > $1.tokens }
    }

    /// Calculate API cost using actual token breakdown
    private func calculateAPIPrice(model: String, stats: ModelUsageStats) -> Double {
        let pricing = PricingService.shared.getPricing(for: model)
        var cost: Double = 0
        cost += Double(stats.inputTokens) * pricing.inputPerMTok / 1_000_000
        cost += Double(stats.outputTokens) * pricing.outputPerMTok / 1_000_000
        cost += Double(stats.cacheCreationInputTokens) * pricing.cacheWritePerMTok / 1_000_000
        cost += Double(stats.cacheReadInputTokens) * pricing.cacheReadPerMTok / 1_000_000
        return cost
    }

    // MARK: - Live Sessions

    var liveSessions: [LiveSession] {
        cachedLiveSessions
    }

    @Published private var cachedLiveSessions: [LiveSession] = []

    private var isUpdatingTranscriptData = false

    // Single pass: update both live sessions and API costs from transcripts
    // Scans ALL project directories once, producing both results
    private func updateTranscriptData(currentMonthOnly: Bool = true) {
        guard !isUpdatingTranscriptData else { return }
        isUpdatingTranscriptData = true

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isUpdatingTranscriptData = false
                    self.isLoadingAPICosts = false
                }
            }

            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let projectsDir = "\(homeDir)/.claude/projects"

            guard FileManager.default.fileExists(atPath: projectsDir) else {
                await MainActor.run {
                    self.cachedLiveSessions = []
                    self.cachedCostBreakdown = APICostBreakdown()
                    MenuBarState.shared.apiCost = nil
                    MenuBarState.shared.dailyApiCost = nil
                    MenuBarState.shared.apiType = .none
                }
                return
            }

            var sessions: [LiveSession] = []
            var breakdown = APICostBreakdown()

            do {
                let directories = try FileManager.default.contentsOfDirectory(atPath: projectsDir)

                for dir in directories {
                    guard !dir.hasPrefix(".") else { continue }

                    let fullDirPath = "\(projectsDir)/\(dir)"
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: fullDirPath, isDirectory: &isDirectory),
                          isDirectory.boolValue else { continue }

                    // Parse transcripts once
                    let usage = self.parseTranscriptsInDirectory(fullDirPath, currentMonthOnly: currentMonthOnly)
                    guard usage.totalTokens > 0 else { continue }

                    // --- Live sessions ---
                    let projectName: String
                    if let range = dir.range(of: "WebstormProjects-") {
                        projectName = String(dir[range.upperBound...])
                    } else if let range = dir.range(of: "branco-") {
                        projectName = String(dir[range.upperBound...])
                    } else {
                        let components = dir.components(separatedBy: "-")
                        projectName = components.suffix(3).joined(separator: "-")
                    }

                    let detectedAPIType: APIType
                    if usage.hasBedrock {
                        detectedAPIType = .bedrock
                    } else if usage.hasClaudeAPI {
                        detectedAPIType = .claudeAPI
                    } else {
                        detectedAPIType = .subscription
                    }

                    let totalCost = usage.isPaidAPI ? usage.calculateCost() : 0

                    sessions.append(LiveSession(
                        id: dir,
                        projectName: projectName,
                        projectPath: dir,
                        lastCost: totalCost,
                        lastTokens: usage.totalTokens,
                        isActive: true,
                        apiType: detectedAPIType
                    ))

                    // --- API cost breakdown ---
                    if usage.isPaidAPI {
                        let projectTotal = usage.calculateCost()
                        let projectMonthly = usage.calculateMonthlyCost()
                        let projectDaily = usage.calculatedDailyCost

                        if usage.hasBedrock {
                            breakdown.bedrockTotal += projectTotal
                            breakdown.bedrockMonthly += projectMonthly
                            breakdown.bedrockDaily += projectDaily
                        } else if usage.hasClaudeAPI {
                            breakdown.claudeAPITotal += projectTotal
                            breakdown.claudeAPIMonthly += projectMonthly
                            breakdown.claudeAPIDaily += projectDaily
                        }
                    }
                }
            } catch {
                // Ignore errors
            }

            let sorted = sessions.sorted {
                if $0.isAPI && !$1.isAPI { return true }
                if !$0.isAPI && $1.isAPI { return false }
                if $0.isAPI { return $0.lastCost > $1.lastCost }
                return $0.lastTokens > $1.lastTokens
            }

            let finalBreakdown = breakdown

            await MainActor.run {
                // Update live sessions
                self.cachedLiveSessions = sorted

                // Update API cost breakdown
                self.cachedCostBreakdown = finalBreakdown

                let monthlyCost = finalBreakdown.totalMonthly
                let dailyCost = finalBreakdown.totalDaily
                if monthlyCost > 0 || dailyCost > 0 {
                    MenuBarState.shared.apiCost = monthlyCost
                    MenuBarState.shared.dailyApiCost = dailyCost
                    if finalBreakdown.hasMultiple {
                        MenuBarState.shared.apiType = .mixed
                    } else if finalBreakdown.hasBedrock {
                        MenuBarState.shared.apiType = .bedrock
                    } else if finalBreakdown.hasClaudeAPI {
                        MenuBarState.shared.apiType = .claudeAPI
                    } else {
                        MenuBarState.shared.apiType = .unknown
                    }
                } else {
                    MenuBarState.shared.apiCost = nil
                    MenuBarState.shared.dailyApiCost = nil
                    MenuBarState.shared.apiType = .none
                }

                self.saveToCache()
                TranscriptCacheService.shared.saveCache()
            }
        }
    }

    // Fast byte-level substring search (avoids String conversion)
    nonisolated private func containsSequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        let limit = haystack.count - needle.count
        for i in 0...limit {
            var match = true
            for j in 0..<needle.count {
                if haystack[i + j] != needle[j] {
                    match = false
                    break
                }
            }
            if match { return true }
        }
        return false
    }

    // Parse transcripts in a directory with GLOBAL deduplication by message ID
    // Uses caching to avoid re-parsing unchanged directories
    // When currentMonthOnly is true, skips messages older than the current month for faster loading
    nonisolated private func parseTranscriptsInDirectory(_ directory: String, currentMonthOnly: Bool = true) -> TranscriptUsage {
        let cacheService = TranscriptCacheService.shared

        // Only use cache for full loads (not month-only partial loads)
        if !currentMonthOnly, let cached = cacheService.getCached(directory: directory) {
            return cacheService.toTranscriptUsage(cached)
        }

        // Parse fresh
        var combinedUsage = TranscriptUsage()

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return combinedUsage
        }

        let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }

        // Global message deduplication across ALL files
        struct MessageEntry {
            let model: String
            let isBedrock: Bool
            let isClaudeAPI: Bool  // Direct Claude API (no service_tier, not Bedrock)
            let isThisMonth: Bool
            let isToday: Bool
            let messageDate: Date?  // For time-based pricing
            let input: Int
            let output: Int
            let thinkingTokens: Int  // Estimated from thinking content (not in output_tokens)
            let cacheCreate: Int
            let cacheRead: Int
        }
        var globalMessageMap: [String: MessageEntry] = [:]
        var thinkingTokensMap: [String: Int] = [:]  // Track max thinking tokens per message ID

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let todayStart = calendar.startOfDay(for: now)

        // Pre-compute byte sequences for fast filtering before JSON parse
        let assistantMarker = Array("\"assistant\"".utf8)
        let usageMarker = Array("\"usage\"".utf8)

        for file in jsonlFiles {
            let fullPath = "\(directory)/\(file)"
            guard let fileHandle = FileHandle(forReadingAtPath: fullPath) else { continue }
            defer { fileHandle.closeFile() }

            let bufferSize = 512 * 1024 // 512 KB chunks
            var buffer = Data()
            var searchStart = 0

            while true {
                let chunk = fileHandle.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                buffer.append(chunk)

                // Process complete lines from buffer
                while searchStart < buffer.count {
                    guard let newlineIndex = buffer[searchStart...].firstIndex(of: 0x0A) else {
                        break // No more complete lines in buffer
                    }

                    let lineRange = searchStart..<newlineIndex
                    let nextStart = newlineIndex + 1

                    // Fast filter: skip lines that don't contain "assistant" or "usage"
                    let lineBytes = Array(buffer[lineRange])
                    let hasAssistant = lineBytes.count > 20 && containsSequence(lineBytes, assistantMarker)

                    if hasAssistant && containsSequence(lineBytes, usageMarker) {
                        // Only parse JSON for lines that likely have assistant messages with usage
                        autoreleasepool {
                            let lineData = buffer.subdata(in: lineRange)
                            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                                  json["type"] as? String == "assistant",
                                  let message = json["message"] as? [String: Any],
                                  let messageId = message["id"] as? String,
                                  let usageData = message["usage"] as? [String: Any] else { return }

                            let model = message["model"] as? String ?? "unknown"
                            let isBedrock = messageId.hasPrefix("msg_bdrk_")

                            var isThisMonth = false
                            var isToday = false
                            var messageDate: Date?
                            if let timestamp = json["timestamp"] as? String {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                var date = formatter.date(from: timestamp)
                                if date == nil {
                                    formatter.formatOptions = [.withInternetDateTime]
                                    date = formatter.date(from: timestamp)
                                }
                                if let date = date {
                                    // Skip old messages when in quick/current-month-only mode
                                    if currentMonthOnly && date < monthStart { return }
                                    isThisMonth = date >= monthStart
                                    isToday = date >= todayStart
                                    messageDate = date
                                }
                            }

                            var thinkingChars = 0
                            if let content = message["content"] as? [[String: Any]] {
                                for block in content {
                                    if block["type"] as? String == "thinking",
                                       let thinking = block["thinking"] as? String {
                                        thinkingChars += thinking.count
                                    }
                                }
                            }
                            let thinkingTokens = Int(Double(thinkingChars) / 2.5)
                            let existingThinking = thinkingTokensMap[messageId] ?? 0
                            thinkingTokensMap[messageId] = max(existingThinking, thinkingTokens)

                            let hasServiceTier = usageData["service_tier"] != nil
                            let isClaudeAPI = !isBedrock && !hasServiceTier
                            let finalThinkingTokens = thinkingTokensMap[messageId] ?? thinkingTokens

                            let entry = MessageEntry(
                                model: model,
                                isBedrock: isBedrock,
                                isClaudeAPI: isClaudeAPI,
                                isThisMonth: isThisMonth,
                                isToday: isToday,
                                messageDate: messageDate,
                                input: usageData["input_tokens"] as? Int ?? 0,
                                output: usageData["output_tokens"] as? Int ?? 0,
                                thinkingTokens: finalThinkingTokens,
                                cacheCreate: usageData["cache_creation_input_tokens"] as? Int ?? 0,
                                cacheRead: usageData["cache_read_input_tokens"] as? Int ?? 0
                            )
                            globalMessageMap[messageId] = entry
                        } // autoreleasepool
                    }

                    searchStart = nextStart
                }

                // Compact: remove processed bytes from buffer
                if searchStart > 0 {
                    buffer.removeSubrange(0..<searchStart)
                    searchStart = 0
                }
            } // while reading chunks
        } // for file in jsonlFiles

        // Accumulate from globally deduplicated messages
        let pricingService = PricingService.shared

        for (_, entry) in globalMessageMap {
            combinedUsage.model = entry.model
            if entry.isBedrock {
                combinedUsage.isBedrock = true
            }
            if entry.isClaudeAPI {
                combinedUsage.isClaudeAPI = true
            }

            // Include thinking tokens in output for display and cost
            combinedUsage.inputTokens += entry.input
            combinedUsage.outputTokens += entry.output + entry.thinkingTokens
            combinedUsage.cacheCreationTokens += entry.cacheCreate
            combinedUsage.cacheReadTokens += entry.cacheRead

            // Calculate cost using pricing for this message's date
            // Thinking tokens are billed at same rate as output tokens
            let messageCost = pricingService.calculateCost(
                inputTokens: entry.input,
                outputTokens: entry.output + entry.thinkingTokens,
                cacheCreationTokens: entry.cacheCreate,
                cacheReadTokens: entry.cacheRead,
                model: entry.model,
                at: entry.messageDate
            )
            combinedUsage.calculatedCost += messageCost

            var modelData = combinedUsage.modelUsage[entry.model] ?? ModelUsageData()
            modelData.inputTokens += entry.input
            modelData.outputTokens += entry.output + entry.thinkingTokens
            modelData.cacheCreationTokens += entry.cacheCreate
            modelData.cacheReadTokens += entry.cacheRead
            combinedUsage.modelUsage[entry.model] = modelData

            if entry.isThisMonth {
                combinedUsage.monthlyInputTokens += entry.input
                combinedUsage.monthlyOutputTokens += entry.output + entry.thinkingTokens
                combinedUsage.monthlyCacheCreationTokens += entry.cacheCreate
                combinedUsage.monthlyCacheReadTokens += entry.cacheRead
                // Only count paid API messages for monthly cost
                if entry.isBedrock || entry.isClaudeAPI {
                    combinedUsage.calculatedMonthlyCost += messageCost
                }

                var monthlyModelData = combinedUsage.monthlyModelUsage[entry.model] ?? ModelUsageData()
                monthlyModelData.inputTokens += entry.input
                monthlyModelData.outputTokens += entry.output + entry.thinkingTokens
                monthlyModelData.cacheCreationTokens += entry.cacheCreate
                monthlyModelData.cacheReadTokens += entry.cacheRead
                combinedUsage.monthlyModelUsage[entry.model] = monthlyModelData
            }

            if entry.isToday {
                combinedUsage.dailyInputTokens += entry.input
                combinedUsage.dailyOutputTokens += entry.output + entry.thinkingTokens
                combinedUsage.dailyCacheCreationTokens += entry.cacheCreate
                combinedUsage.dailyCacheReadTokens += entry.cacheRead
                // Only count paid API messages for daily cost
                if entry.isBedrock || entry.isClaudeAPI {
                    combinedUsage.calculatedDailyCost += messageCost
                }
            }
        }

        // Only cache full loads (partial month-only data shouldn't pollute cache)
        if !currentMonthOnly {
            cacheService.cacheDirectory(directory: directory, usage: combinedUsage)
        }

        return combinedUsage
    }

    var recentSessions: [LiveSession] {
        Array(liveSessions.prefix(5))
    }

    // MARK: - API Cost Summary

    private let transcriptParser = TranscriptParser()
    @Published var cachedCostBreakdown = APICostBreakdown()
    @Published var isLoadingAPICosts = true  // Start true, set false when done

    var hasAPIProjects: Bool {
        cachedCostBreakdown.hasBedrock || cachedCostBreakdown.hasClaudeAPI
    }

    var showAPICostCard: Bool {
        isLoadingAPICosts || hasAPIProjects
    }

    var hasBedrockProjects: Bool {
        cachedCostBreakdown.hasBedrock
    }

    var hasClaudeAPIProjects: Bool {
        cachedCostBreakdown.hasClaudeAPI
    }

    var totalAPICost: Double {
        cachedCostBreakdown.totalAll
    }

    var monthlyAPICost: Double {
        cachedCostBreakdown.totalMonthly
    }

    var dailyAPICost: Double {
        cachedCostBreakdown.totalDaily
    }

    var apiCostBreakdown: APICostBreakdown {
        cachedCostBreakdown
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
