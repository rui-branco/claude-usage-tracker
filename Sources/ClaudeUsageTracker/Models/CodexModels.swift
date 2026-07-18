import Foundation

// MARK: - Raw JSONL payloads

struct CodexEnvelope: Decodable {
    let timestamp: String?
    let type: String?
    let payload: CodexPayload?
}

struct CodexPayload: Decodable {
    // session_meta
    let id: String?
    let cwd: String?
    let timestamp: String?
    let originator: String?
    let cliVersion: String?
    let modelProvider: String?

    // event_msg discriminator + token_count fields
    let type: String?
    let info: CodexTokenInfo?
    let rateLimits: CodexRateLimitsRaw?
    let modelContextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case id, cwd, timestamp, originator, type, info
        case cliVersion = "cli_version"
        case modelProvider = "model_provider"
        case rateLimits = "rate_limits"
        case modelContextWindow = "model_context_window"
    }
}

struct CodexTokenInfo: Decodable {
    let totalTokenUsage: CodexTokenUsage?
    let modelContextWindow: Int?

    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case modelContextWindow = "model_context_window"
    }
}

struct CodexTokenUsage: Decodable {
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
    }
}

struct CodexRateLimitsRaw: Decodable {
    let primary: CodexRateWindowRaw?
    let secondary: CodexRateWindowRaw?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case planType = "plan_type"
    }
}

struct CodexRateWindowRaw: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Int?  // epoch seconds

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

// MARK: - Presentation models

struct CodexRateLimitStatus {
    let planType: String
    let weeklyUsedPercent: Double
    let weeklyResetAt: Date
    let updatedAt: Date

    /// Stale when the window has rolled over (saved reset already elapsed) OR the
    /// observation is too old to trust. The live usage API refreshes updatedAt
    /// every ~60s; a value older than that means the API is unreachable and we've
    /// fallen back to the last rollout parse, which may be out of date.
    var isStale: Bool {
        weeklyResetAt < Date() || Date().timeIntervalSince(updatedAt) > 30 * 60
    }
}

/// A live codex session = a currently running codex CLI process plus (optionally)
/// the most recent rollout file we could match to it.
struct CodexLiveSession: Identifiable, Equatable {
    let id: String              // pid as string (mirrors LiveClaudeSession)
    let pid: Int32
    let projectPath: String
    let projectName: String
    let memoryMB: Int
    let totalTokens: Int?       // from rollout, may be nil if no match
}

// MARK: - Live usage API (chatgpt.com/backend-api/codex/usage)

/// Subset of ~/.codex/auth.json needed to authenticate the usage request.
struct CodexAuthFile: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }
    let tokens: Tokens?
}

struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexUsageRateLimit?
    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

struct CodexUsageRateLimit: Decodable {
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?
    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexUsageWindow: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAt: Int?
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}
