import Foundation

// MARK: - OAuth credentials file (~/.gemini/oauth_creds.json)

struct GeminiOAuthCreds: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiryDate: Double?  // epoch milliseconds

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiryDate = "expiry_date"
    }
}

// MARK: - Quota API (cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota)

struct GeminiQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]?
}

struct GeminiQuotaBucket: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
    let modelId: String?
    let tokenType: String?
    /// Sent only on paid Code Assist plans when a project ID is included. Absolute
    /// number of remaining requests (string-encoded int).
    let remainingAmount: String?
}

// MARK: - Session JSONL header (~/.gemini/tmp/<project>/chats/session-*.jsonl)

struct GeminiSessionHeader: Decodable {
    let sessionId: String?
    let projectHash: String?
    let startTime: String?
    let lastUpdated: String?
    let kind: String?
}

// MARK: - Per-turn row with token usage

struct GeminiSessionTurn: Decodable {
    let type: String?
    let model: String?
    let tokens: GeminiTokenUsage?
}

struct GeminiTokenUsage: Decodable {
    let input: Int?
    let output: Int?
    let cached: Int?
    let thoughts: Int?
    let tool: Int?
    let total: Int?
}

// MARK: - projects.json map

struct GeminiProjectsFile: Decodable {
    let projects: [String: String]?  // absolute path -> short name
}

// MARK: - Presentation models

struct GeminiRateLimitStatus {
    /// The most-constrained model: this is what drives the menu bar gauge.
    let model: String
    /// Used % = 100 - (remaining fraction * 100), for the most-constrained model.
    let usedPercent: Double
    /// When that model's quota resets, if known.
    let resetAt: Date?
    let updatedAt: Date
    /// All models keyed by id with their usedPercent + reset, for showing per-model bars.
    let perModel: [(model: String, usedPercent: Double, resetAt: Date?)]

    var isStale: Bool {
        // No reset time means we can't tell; rely on updatedAt being recent.
        Date().timeIntervalSince(updatedAt) > 30 * 60
    }
}

struct GeminiLiveSession: Identifiable, Equatable {
    let id: String              // pid as string
    let pid: Int32
    let projectPath: String
    let projectName: String
    let memoryMB: Int
    let totalTokens: Int?
    let modelName: String?

    static func == (lhs: GeminiLiveSession, rhs: GeminiLiveSession) -> Bool {
        lhs.id == rhs.id
            && lhs.projectPath == rhs.projectPath
            && lhs.memoryMB == rhs.memoryMB
            && lhs.totalTokens == rhs.totalTokens
            && lhs.modelName == rhs.modelName
    }
}
