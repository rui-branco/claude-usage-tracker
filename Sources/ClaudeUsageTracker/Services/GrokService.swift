import Foundation
import Combine

@MainActor
final class GrokService: ObservableObject {
    @Published var rateLimits: GrokRateLimitStatus?
    @Published var isLoading: Bool = true
    @Published var authState: GrokAuthState = .unknown

    enum GrokAuthState: Equatable {
        case unknown
        case authenticated
        case notAuthenticated(reason: String)
    }

    private var timer: Timer?
    /// Poll interval — the Grok quota endpoint is lightweight but we don't want
    /// to hammer it. 60s matches the Codex/Gemini cadence.
    private let pollInterval: TimeInterval = 60

    func start() {
        Task { await probeUsage() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.probeUsage()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task { await probeUsage() }
    }

    /// Triggers an extra refresh when the popover opens.
    func setPopoverVisible(_ visible: Bool) {
        if visible { Task { await probeUsage() } }
    }

    // MARK: - Usage Probe

    private func probeUsage() async {
        let result = await Task.detached(priority: .utility) {
            GrokService.fetchUsageSync()
        }.value

        switch result {
        case .success(let status):
            self.rateLimits = status
            self.authState = .authenticated
            if !status.isStale {
                MenuBarState.shared.grokWeeklyPercent = Int(status.usedPercent.rounded())
            } else {
                MenuBarState.shared.grokWeeklyPercent = nil
            }

        case .authFailure(let reason):
            self.authState = .notAuthenticated(reason: reason)
            MenuBarState.shared.grokWeeklyPercent = nil

        case .networkError:
            // Keep existing data, just don't update
            if let existing = self.rateLimits, existing.isStale {
                MenuBarState.shared.grokWeeklyPercent = nil
            }
        }

        self.isLoading = false
    }

    // MARK: - Sync Fetch (background thread)

    private enum FetchResult {
        case success(GrokRateLimitStatus)
        case authFailure(String)
        case networkError
    }

    /// Grok CLI auth.json structure (only fields we need).
    private struct CLIAuth {
        let accessToken: String
        let expiresAt: Date
    }

    /// Reads ~/.grok/auth.json and extracts the access token if valid.
    /// The file structure is: { "<issuer>::<id>": { "key": "...", "expires_at": "...", ... } }
    nonisolated private static func readCLIAuth() -> CLIAuth? {
        let authPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // The auth data is nested under the first (and typically only) issuer key
        guard let firstEntry = json.values.first as? [String: Any],
              let token = firstEntry["key"] as? String,
              !token.isEmpty else {
            return nil
        }

        // Also check for "expires_at" in the nested object
        let authData = firstEntry

        // Parse expires_at (ISO8601 string)
        var expiresAt = Date.distantFuture
        if let expiresStr = authData["expires_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: expiresStr) {
                expiresAt = date
            } else {
                // Try without fractional seconds
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: expiresStr) {
                    expiresAt = date
                }
            }
        }

        // Reject if expired (with 60s buffer)
        guard expiresAt > Date().addingTimeInterval(60) else {
            return nil
        }

        return CLIAuth(accessToken: token, expiresAt: expiresAt)
    }

    nonisolated private static func fetchUsageSync() -> FetchResult {
        // Read CLI auth from ~/.grok/auth.json
        guard let cliAuth = readCLIAuth() else {
            let authPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok/auth.json")
            if FileManager.default.fileExists(atPath: authPath.path) {
                return .authFailure("Grok CLI token expired. Run: grok login")
            }
            return .authFailure("Run: grok login")
        }

        // Try the gRPC-Web endpoint first
        switch fetchGrokCreditsConfigBearer(token: cliAuth.accessToken) {
        case .success(let status):
            return .success(status)
        case .authRequired:
            return .authFailure("Grok CLI token rejected. Run: grok login")
        case .error:
            // Network/parse error with valid token, try CLI billing endpoint
            switch fetchCLIBillingEndpoint(token: cliAuth.accessToken) {
            case .success(let status):
                return .success(status)
            case .authRequired:
                return .authFailure("Grok CLI token rejected. Run: grok login")
            case .error:
                return .networkError
            }
        }
    }

    // MARK: - Grok API Calls

    private enum GrokAPIResult {
        case success(GrokRateLimitStatus)
        case authRequired
        case error
    }

    /// Fetches the Grok credits config using bearer token auth (CLI credentials).
    nonisolated private static func fetchGrokCreditsConfigBearer(token: String) -> GrokAPIResult {
        guard let url = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig") else {
            return .error
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        // gRPC-Web headers with bearer auth
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/", forHTTPHeaderField: "Referer")

        // Empty gRPC-Web frame
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode = 0

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            if let http = response as? HTTPURLResponse {
                responseCode = http.statusCode
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)

        if responseCode == 401 || responseCode == 403 {
            return .authRequired
        }

        guard responseCode == 200, let data = responseData else {
            return .error
        }

        do {
            let parsed = try GrokProtobufParser.parse(data)
            return .success(GrokRateLimitStatus(
                usedPercent: parsed.usedPercent,
                periodStart: parsed.periodStart,
                resetAt: parsed.resetAt,
                updatedAt: Date()
            ))
        } catch GrokProtobufParser.ParseError.authRequired {
            return .authRequired
        } catch {
            return .error
        }
    }

    /// Fetches usage from the CLI billing endpoint (fallback for CLI auth).
    nonisolated private static func fetchCLIBillingEndpoint(token: String) -> GrokAPIResult {
        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
            return .error
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode = 0

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            if let http = response as? HTTPURLResponse {
                responseCode = http.statusCode
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 20)

        if responseCode == 401 || responseCode == 403 {
            return .authRequired
        }

        guard responseCode == 200, let data = responseData else {
            return .error
        }

        // Parse JSON response: look for usage/limit or percent fields
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .error
        }

        // Try common schema patterns
        var usedPercent: Double?
        var resetAt: Date?

        // Pattern 1: { "used": X, "limit": Y } or { "credits_used": X, "credits_limit": Y }
        if let used = (json["used"] as? Double) ?? (json["credits_used"] as? Double),
           let limit = (json["limit"] as? Double) ?? (json["credits_limit"] as? Double),
           limit > 0 {
            usedPercent = (used / limit) * 100.0
        }

        // Pattern 2: { "percent_used": X } or { "usage_percent": X }
        if usedPercent == nil {
            usedPercent = (json["percent_used"] as? Double) ?? (json["usage_percent"] as? Double)
        }

        // Pattern 3: nested { "usage": { "percent": X } }
        if usedPercent == nil, let usage = json["usage"] as? [String: Any] {
            usedPercent = usage["percent"] as? Double
        }

        // Reset time
        if let resetStr = (json["reset_at"] as? String) ?? (json["resets_at"] as? String) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetAt = formatter.date(from: resetStr)
            if resetAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                resetAt = formatter.date(from: resetStr)
            }
        }

        guard let percent = usedPercent else {
            return .error
        }

        return .success(GrokRateLimitStatus(
            usedPercent: percent,
            periodStart: nil,
            resetAt: resetAt,
            updatedAt: Date()
        ))
    }
}
