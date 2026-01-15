import Foundation

struct ClaudeConfig: Codable {
    let numStartups: Int?
    let projects: [String: ProjectConfig]?
    let oauthAccount: OAuthAccount?
}

struct ProjectConfig: Codable {
    let lastCost: Double?
    let lastTotalInputTokens: Int?
    let lastTotalOutputTokens: Int?
    let lastTotalCacheCreationInputTokens: Int?
    let lastTotalCacheReadInputTokens: Int?
    let lastModelUsage: [String: ProjectModelUsage]?
    let lastSessionId: String?
}

struct ProjectModelUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let webSearchRequests: Int?
    let costUSD: Double?
}

struct OAuthAccount: Codable {
    let accountUuid: String?
    let emailAddress: String?
    let organizationUuid: String?
    let displayName: String?
    let organizationName: String?
}
