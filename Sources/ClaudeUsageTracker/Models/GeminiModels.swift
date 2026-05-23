import Foundation

// MARK: - OAuth credentials (file or Keychain)

/// Unified OAuth credentials used by both the legacy Gemini CLI (file at
/// ~/.gemini/oauth_creds.json, epoch-ms expiry) and the Antigravity CLI
/// (macOS Keychain: service=gemini, account=antigravity, with the token
/// nested under `token` and ISO-8601 expiry).
struct GeminiOAuthCreds {
    let accessToken: String
    let expiry: Date?
}

/// Wire format for the legacy gemini-cli file.
struct GeminiFileCreds: Decodable {
    let accessToken: String?
    let expiryDate: Double?  // epoch milliseconds

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiryDate = "expiry_date"
    }
}

/// Wire format for the Antigravity Keychain entry. The Keychain value is
/// `go-keyring-base64:<base64-encoded JSON>` and the JSON wraps the OAuth
/// token under a `token` key.
struct GeminiKeychainCreds: Decodable {
    struct Token: Decodable {
        let accessToken: String?
        let expiry: String?  // ISO-8601, e.g. "2026-05-20T21:23:40.010309+01:00"

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiry
        }
    }
    let token: Token?
}

// MARK: - Quota API (cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels)
//
// Requires `User-Agent: antigravity` plus `{"project": "<cloudaicompanionProject>"}`
// in the body. Returns the friendly per-effort model catalog Antigravity's TUI
// quota view uses (e.g. "Gemini 3.1 Pro (High)", "Claude Sonnet 4.6 (Thinking)")
// with each entry's remaining quota and reset time.

struct GeminiAvailableModelsResponse: Decodable {
    let models: [String: GeminiAvailableModel]?
}

struct GeminiAvailableModel: Decodable {
    let displayName: String?
    let quotaInfo: GeminiQuotaInfo?
    let disabled: Bool?
    let beta: Bool?
}

struct GeminiQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
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
