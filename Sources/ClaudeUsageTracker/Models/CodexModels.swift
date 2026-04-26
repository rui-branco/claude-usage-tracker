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
    let primaryUsedPercent: Double
    let secondaryUsedPercent: Double
    let primaryResetAt: Date
    let secondaryResetAt: Date
    let updatedAt: Date

    /// True when the saved 5h reset has already elapsed — the displayed % is from
    /// a previous window, not the current one.
    var primaryIsStale: Bool { primaryResetAt < Date() }

    /// Same idea for the weekly window.
    var secondaryIsStale: Bool { secondaryResetAt < Date() }
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
