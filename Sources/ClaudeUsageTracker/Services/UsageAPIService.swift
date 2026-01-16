import Foundation
import Security

/// Service to fetch rate limit usage from Anthropic API
final class UsageAPIService: @unchecked Sendable {
    static let shared = UsageAPIService()

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private var cachedUsage: UsageResponse?
    private var lastFetch: Date?
    private let cacheDuration: TimeInterval = 60 // Cache for 60 seconds

    struct UsageResponse: Codable {
        let fiveHour: UsageWindow
        let sevenDay: UsageWindow

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    struct UsageWindow: Codable {
        let utilization: Double  // 0-100 percentage
        let resetAt: String      // ISO8601 timestamp

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetAt = "reset_at"
        }
    }

    struct KeychainCredentials: Codable {
        let claudeAiOauth: OAuthCredentials?
        // Fallback for flat structure
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: String?
    }

    struct OAuthCredentials: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: String?
    }

    /// Fetch usage data, using cache if fresh
    func fetchUsage() async throws -> UsageResponse {
        // Check cache
        if let cached = cachedUsage,
           let lastFetch = lastFetch,
           Date().timeIntervalSince(lastFetch) < cacheDuration {
            return cached
        }

        // Get credentials
        guard let token = getAccessToken() else {
            throw UsageAPIError.noCredentials
        }

        // Make request
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeUsageTracker/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            NSLog("[UsageAPI] Error: HTTP %d", httpResponse.statusCode)
            throw UsageAPIError.httpError(httpResponse.statusCode)
        }

        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)

        // Cache result
        cachedUsage = usage
        lastFetch = Date()

        NSLog("[UsageAPI] Fetched: 5h=%.1f%%, 7d=%.1f%%", usage.fiveHour.utilization, usage.sevenDay.utilization)

        return usage
    }

    /// Get access token from Keychain or credentials file
    private func getAccessToken() -> String? {
        // Try Keychain first (macOS)
        if let token = getTokenFromKeychain() {
            return token
        }

        // Fallback to credentials file
        if let token = getTokenFromFile() {
            return token
        }

        return nil
    }

    /// Read token from macOS Keychain
    private func getTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let jsonString = String(data: data, encoding: .utf8) else {
            NSLog("[UsageAPI] Failed to read keychain: %d", status)
            return nil
        }

        // Parse JSON credentials
        guard let jsonData = jsonString.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(KeychainCredentials.self, from: jsonData) else {
            NSLog("[UsageAPI] Failed to parse keychain JSON")
            return nil
        }

        // Try nested structure first (claudeAiOauth.accessToken)
        if let oauth = credentials.claudeAiOauth {
            // Check expiration if available
            if let expiresAt = oauth.expiresAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let expirationDate = formatter.date(from: expiresAt),
                   expirationDate < Date() {
                    NSLog("[UsageAPI] Token expired")
                    return nil
                }
            }
            NSLog("[UsageAPI] Got token from keychain (nested)")
            return oauth.accessToken
        }

        // Fallback to flat structure
        if let token = credentials.accessToken {
            NSLog("[UsageAPI] Got token from keychain (flat)")
            return token
        }

        NSLog("[UsageAPI] No access token found in keychain")
        return nil
    }

    /// Read token from ~/.claude/.credentials.json
    private func getTokenFromFile() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let credentialsPath = "\(homeDir)/.claude/.credentials.json"

        guard let data = FileManager.default.contents(atPath: credentialsPath),
              let credentials = try? JSONDecoder().decode(KeychainCredentials.self, from: data) else {
            return nil
        }

        // Try nested structure first
        if let oauth = credentials.claudeAiOauth {
            return oauth.accessToken
        }
        // Fallback to flat structure
        return credentials.accessToken
    }

    /// Clear cached data
    func clearCache() {
        cachedUsage = nil
        lastFetch = nil
    }
}

enum UsageAPIError: Error {
    case noCredentials
    case invalidResponse
    case httpError(Int)
}
