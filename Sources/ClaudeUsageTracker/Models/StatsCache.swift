import Foundation

struct StatsCache: Codable {
    let version: Int
    let lastComputedDate: String
    let dailyActivity: [DailyActivity]
    let dailyModelTokens: [DailyModelTokens]
    let modelUsage: [String: ModelUsageStats]
    let totalSessions: Int
    let totalMessages: Int
    let longestSession: SessionInfo?
    let firstSessionDate: String?
    let hourCounts: [String: Int]?
}

struct DailyActivity: Codable, Identifiable {
    var id: String { date }
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

struct DailyModelTokens: Codable, Identifiable {
    var id: String { date }
    let date: String
    let tokensByModel: [String: Int]
}

struct ModelUsageStats: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let webSearchRequests: Int
    let costUSD: Double
    let contextWindow: Int?
    let maxOutputTokens: Int?
}

struct SessionInfo: Codable {
    let sessionId: String
    let duration: Int
    let messageCount: Int
    let timestamp: String
}
