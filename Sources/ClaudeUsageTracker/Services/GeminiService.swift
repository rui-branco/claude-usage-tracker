import Foundation
import Combine

@MainActor
final class GeminiService: ObservableObject {
    @Published var rateLimits: GeminiRateLimitStatus?
    @Published var sessions: [GeminiLiveSession] = []
    @Published var isLoading: Bool = true
    @Published var hasGeminiInstalled: Bool = false

    private var timer: Timer?
    private var quotaTimer: Timer?
    private let activeScanInterval: TimeInterval = 5
    private let idleScanInterval: TimeInterval = 30
    private var isPopoverVisible: Bool = false
    /// Quota POST is more expensive — poll it less aggressively than session scan.
    private let quotaInterval: TimeInterval = 60
    private let sessionLookbackMinutes: Int = 60
    private let maxFileSize: Int = 10 * 1024 * 1024

    /// Memoized parsed session JSONL keyed by file path, invalidated on
    /// (mtime, size) change. Skipping re-parse of unchanged files is the
    /// dominant CPU saving across rapid timer ticks.
    private var sessionCache: [String: CachedSession] = [:]

    nonisolated private struct CachedSession {
        let mtime: Date
        let size: Int
        let parsed: ParsedSession
    }

    private var geminiRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }
    private var tmpRoot: URL { geminiRoot.appendingPathComponent("tmp") }
    private var credsURL: URL { geminiRoot.appendingPathComponent("oauth_creds.json") }
    private var projectsFileURL: URL { geminiRoot.appendingPathComponent("projects.json") }

    /// GCP project id to send with the quota POST. Without it the endpoint returns
    /// placeholder fractions; with it we get real per-model usage. Cached on first
    /// successful discovery via cloudresourcemanager.googleapis.com.
    private var cachedProjectId: String?

    func start() {
        Task { await scan() }
        Task { await probeQuota() }
        scheduleScanTimer()
        quotaTimer = Timer.scheduledTimer(withTimeInterval: quotaInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.probeQuota()
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        quotaTimer?.invalidate(); quotaTimer = nil
    }

    func refresh() {
        Task { await scan() }
        Task { await probeQuota() }
    }

    /// Called from the menu-bar popover lifecycle. Slows the session scanner
    /// to 30s when the user can't see the data. The quota timer is already
    /// at 60s — and it (not scan) is what publishes the menu-bar Gemini % —
    /// so the visible label is unaffected by this throttle.
    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        scheduleScanTimer()
        if visible { Task { await scan() } }
    }

    private func scheduleScanTimer() {
        timer?.invalidate()
        let interval = isPopoverVisible ? activeScanInterval : idleScanInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scan()
            }
        }
    }

    // MARK: - Session scan (off-main)

    private func scan() async {
        let root = tmpRoot
        let projectsURL = projectsFileURL
        let installed = FileManager.default.fileExists(atPath: geminiRoot.path)
        self.hasGeminiInstalled = installed

        let cacheSnapshot = sessionCache
        let result = await Task.detached(priority: .utility) { [lookback = sessionLookbackMinutes, cap = maxFileSize] in
            GeminiService.scanCurrent(
                tmpRoot: root,
                projectsURL: projectsURL,
                lookbackMinutes: lookback,
                maxFileSize: cap,
                installed: installed,
                cache: cacheSnapshot
            )
        }.value

        self.sessionCache = result.updatedCache
        self.sessions = result.sessions
        self.isLoading = false
    }

    // MARK: - Quota probe (off-main)

    private func probeQuota() async {
        let creds = credsURL
        let cachedProject = cachedProjectId
        let result = await Task.detached(priority: .utility) {
            GeminiService.fetchQuotaSync(credsURL: creds, projectId: cachedProject)
        }.value
        let fetched = result.status
        if let discovered = result.projectId { self.cachedProjectId = discovered }

        if let fetched = fetched {
            self.rateLimits = fetched
            if !fetched.isStale {
                MenuBarState.shared.geminiSessionPercent = Int(fetched.usedPercent.rounded())
            } else {
                MenuBarState.shared.geminiSessionPercent = nil
            }
        } else if let cached = self.rateLimits, !cached.isStale {
            MenuBarState.shared.geminiSessionPercent = Int(cached.usedPercent.rounded())
        } else {
            MenuBarState.shared.geminiSessionPercent = nil
        }
    }

    // MARK: - Heavy lifting

    nonisolated private struct ScanResult {
        let sessions: [GeminiLiveSession]
        let updatedCache: [String: CachedSession]
    }

    nonisolated private static func scanCurrent(
        tmpRoot: URL,
        projectsURL: URL,
        lookbackMinutes: Int,
        maxFileSize: Int,
        installed: Bool,
        cache: [String: CachedSession]
    ) -> ScanResult {
        // 1. Detect running gemini processes
        let processes = listGeminiProcesses()
        guard installed else {
            // Even with no ~/.gemini, surface bare process info
            let bare = processes.map { proc in
                GeminiLiveSession(
                    id: "\(proc.pid)",
                    pid: proc.pid,
                    projectPath: proc.cwd,
                    projectName: proc.cwd.isEmpty ? "Gemini \(proc.pid)" : URL(fileURLWithPath: proc.cwd).lastPathComponent,
                    memoryMB: proc.memMB,
                    totalTokens: nil,
                    modelName: nil
                )
            }
            return ScanResult(sessions: bare, updatedCache: [:])
        }

        // 2. Build cwd -> project shortname map from projects.json
        let projectMap = loadProjectMap(projectsURL)

        // 3. Index recent session files by project shortname, keep newest per project.
        //    Reuse cached parse results when (mtime, size) is unchanged.
        let cutoff = Date().addingTimeInterval(-Double(lookbackMinutes) * 60)
        var rolloutsByProject: [String: (mtime: Date, totalTokens: Int?, modelName: String?)] = [:]
        var nextCache: [String: CachedSession] = [:]
        if let projects = try? FileManager.default.contentsOfDirectory(at: tmpRoot, includingPropertiesForKeys: nil) {
            for projDir in projects {
                let chatsDir = projDir.appendingPathComponent("chats")
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: chatsDir,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for url in files where url.pathExtension == "jsonl" {
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let mtime = attrs[.modificationDate] as? Date,
                          let size = attrs[.size] as? Int,
                          mtime >= cutoff,
                          size <= maxFileSize else { continue }

                    let cacheKey = url.path
                    let parsed: ParsedSession
                    if let cached = cache[cacheKey], cached.size == size, cached.mtime == mtime {
                        parsed = cached.parsed
                    } else {
                        parsed = parseSession(url)
                    }
                    nextCache[cacheKey] = CachedSession(mtime: mtime, size: size, parsed: parsed)

                    let key = projDir.lastPathComponent
                    let entry = (mtime: mtime, totalTokens: parsed.totalTokens, modelName: parsed.modelName)
                    if let existing = rolloutsByProject[key] {
                        if mtime > existing.mtime { rolloutsByProject[key] = entry }
                    } else {
                        rolloutsByProject[key] = entry
                    }
                }
            }
        }

        // 4. Build live session list, keyed by cwd. Match running processes to rollouts via projects.json.
        var byCwd: [String: GeminiLiveSession] = [:]
        for proc in processes {
            let cwd = proc.cwd
            let projectName = cwd.isEmpty
                ? "Gemini \(proc.pid)"
                : URL(fileURLWithPath: cwd).lastPathComponent

            var totalTokens: Int?
            var modelName: String?
            if !cwd.isEmpty, let shortName = projectMap[cwd], let r = rolloutsByProject[shortName] {
                totalTokens = r.totalTokens
                modelName = r.modelName
            }

            let key = cwd.isEmpty ? "pid-\(proc.pid)" : cwd
            let candidate = GeminiLiveSession(
                id: "\(proc.pid)",
                pid: proc.pid,
                projectPath: cwd,
                projectName: projectName,
                memoryMB: proc.memMB,
                totalTokens: totalTokens,
                modelName: modelName
            )

            if let existing = byCwd[key] {
                if candidate.memoryMB > existing.memoryMB { byCwd[key] = candidate }
            } else {
                byCwd[key] = candidate
            }
        }

        let sessions = Array(byCwd.values).sorted { $0.memoryMB > $1.memoryMB }
        return ScanResult(sessions: sessions, updatedCache: nextCache)
    }

    nonisolated private static func loadProjectMap(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GeminiProjectsFile.self, from: data),
              let projects = decoded.projects else { return [:] }
        return projects
    }

    // MARK: - Process detection

    nonisolated private struct GeminiProcess {
        let pid: Int32
        let memMB: Int
        let cwd: String
    }

    nonisolated private static func listGeminiProcesses() -> [GeminiProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axwwo", "pid,rss,command"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return parseGeminiProcessList(output)
        } catch {
            return []
        }
    }

    nonisolated private static func parseGeminiProcessList(_ output: String) -> [GeminiProcess] {
        var result: [GeminiProcess] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            if line.contains("ClaudeUsageTracker")
                || line.contains("grep ")
                || line.contains("ps -axwwo")
                || line.contains("claude-commands-mcp")
                || line.contains("Google Chrome")
                || line.contains("/Gemini.app/")            // Gemini macOS desktop app
                || line.contains("/Antigravity.app/")       // Antigravity macOS desktop app
                || line.contains("gemini-cli-mcp")
                || line.contains("forge-deck") {
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let cols = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count >= 3,
                  let pid = Int32(cols[0]),
                  let rssKB = Int(cols[1]) else { continue }
            let cmdField = String(cols[2])

            // Gemini CLI is installed via npm. Match either the wrapper bin/gemini
            // or a node process whose command line contains gemini-cli's entrypoint.
            let isGeminiWrapper = line.contains("/bin/gemini ") || line.hasSuffix("/bin/gemini")
            let isNodeGemini = line.contains("node") && (
                line.contains("@google/gemini-cli") ||
                line.contains("/gemini-cli/") ||
                line.contains("/gemini/dist/")
            )
            // Antigravity ships as the `agy` Go binary; match by first command
            // token only — "agy" is too short for substring matching.
            let firstToken = cmdField.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let isAgy = (firstToken as NSString).lastPathComponent == "agy"

            guard isGeminiWrapper || isNodeGemini || isAgy else { continue }

            let cwd = workingDirectory(for: pid)
            result.append(GeminiProcess(pid: pid, memMB: rssKB / 1024, cwd: cwd))
        }
        return result
    }

    nonisolated private static func workingDirectory(for pid: Int32) -> String {
        ProcCwd.of(pid: pid) ?? ""
    }

    // MARK: - Session JSONL parser

    nonisolated private struct ParsedSession {
        let totalTokens: Int?
        let modelName: String?
    }

    nonisolated private static func parseSession(_ url: URL) -> ParsedSession {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ParsedSession(totalTokens: nil, modelName: nil)
        }
        let decoder = JSONDecoder()

        var latestTotal: Int?
        var latestModel: String?

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = raw.data(using: .utf8) else { continue }
            if let turn = try? decoder.decode(GeminiSessionTurn.self, from: lineData) {
                if let t = turn.tokens?.total { latestTotal = (latestTotal ?? 0) + t }
                if let m = turn.model, !m.isEmpty { latestModel = m }
            }
        }
        return ParsedSession(totalTokens: latestTotal, modelName: latestModel)
    }

    // MARK: - Quota API (sync helper running on a background queue)

    nonisolated private struct QuotaResult {
        let status: GeminiRateLimitStatus?
        /// Newly-discovered project ID, if we had to look one up this call.
        let projectId: String?
    }

    nonisolated private static func fetchQuotaSync(credsURL: URL, projectId: String?) -> QuotaResult {
        // Prefer the Keychain entry written by Antigravity (`agy`), which keeps
        // the token refreshed. Fall back to the legacy ~/.gemini/oauth_creds.json
        // file for users still on the old gemini-cli.
        guard let creds = loadKeychainCreds() ?? loadFileCreds(credsURL),
              !creds.accessToken.isEmpty else { return QuotaResult(status: nil, projectId: nil) }
        let token = creds.accessToken

        // Skip when the token has clearly expired — avoid a guaranteed 401.
        if let expiry = creds.expiry, expiry < Date() {
            return QuotaResult(status: nil, projectId: nil)
        }

        // Antigravity quota is keyed by the user's "cloudaicompanion" project;
        // LoadCodeAssist returns it.
        var discoveredProject: String?
        let activeProject: String
        if let projectId = projectId {
            activeProject = projectId
        } else if let found = loadCloudAICompanionProject(token: token) {
            discoveredProject = found
            activeProject = found
        } else {
            // fetchAvailableModels requires the project field — no point calling without it.
            return QuotaResult(status: nil, projectId: nil)
        }

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels") else {
            return QuotaResult(status: nil, projectId: discoveredProject)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The endpoint returns 403 PERMISSION_DENIED unless the request advertises
        // itself as antigravity — agy sets this exact User-Agent string.
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        let body: [String: String] = ["project": activeProject]
        request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode: Int = 0

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            if let http = response as? HTTPURLResponse { responseCode = http.statusCode }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 12)

        guard responseCode == 200, let data = responseData,
              let decoded = try? JSONDecoder().decode(GeminiAvailableModelsResponse.self, from: data),
              let models = decoded.models, !models.isEmpty else {
            return QuotaResult(status: nil, projectId: discoveredProject)
        }

        // Many model IDs map to the same human-readable label (e.g. gemini-3-flash-agent,
        // gemini-pro-agent both alias to a labeled tier). Group by displayName, keep one
        // entry per label with the lowest remaining fraction (= worst-case for that tier).
        // Also drop entries with no displayName (background suggestion models like
        // tab_flash_lite_preview / chat_NNNN) and disabled models.
        var byLabel: [String: (fraction: Double, resetTime: String?)] = [:]
        for (_, model) in models {
            guard let label = model.displayName, !label.isEmpty,
                  // Mirror Antigravity's own Model Quota view: only curated tier
                  // variants — i.e. labels with an effort/thinking suffix in parens
                  // like "(High)", "(Low)", "(Medium)", "(Thinking)". Drops the raw
                  // entries ("Gemini 2.5 Pro", "Gemini 3 Flash", "Gemini 3.1 Flash
                  // Image", "Gemini 3.1 Flash Lite") that share quota with a tier.
                  label.contains("("),
                  let quota = model.quotaInfo,
                  let fraction = quota.remainingFraction,
                  model.disabled != true else { continue }
            if let existing = byLabel[label] {
                if fraction < existing.fraction {
                    byLabel[label] = (fraction, quota.resetTime)
                }
            } else {
                byLabel[label] = (fraction, quota.resetTime)
            }
        }
        guard !byLabel.isEmpty else {
            return QuotaResult(status: nil, projectId: discoveredProject)
        }

        // Only surface tiers the user has actually used. Display rounds to 0%
        // below 0.5%, so anything lower is just visual noise. If nothing's been
        // touched, return a nil status so the whole ANTIGRAVITY section hides.
        let perModel: [(model: String, usedPercent: Double, resetAt: Date?)] = byLabel
            .sorted { $0.key < $1.key }
            .compactMap { entry in
                let used = max(0, min(100, (1.0 - entry.value.fraction) * 100))
                guard used >= 0.5 else { return nil }
                return (model: entry.key,
                        usedPercent: used,
                        resetAt: entry.value.resetTime.flatMap(parseISODate))
            }
        guard let worst = perModel.max(by: { $0.usedPercent < $1.usedPercent }) else {
            return QuotaResult(status: nil, projectId: discoveredProject)
        }

        let status = GeminiRateLimitStatus(
            model: worst.model,
            usedPercent: worst.usedPercent,
            resetAt: worst.resetAt,
            updatedAt: Date(),
            perModel: perModel
        )
        return QuotaResult(status: status, projectId: discoveredProject)
    }

    // MARK: - OAuth creds loaders

    /// Antigravity (`agy`) stores its OAuth token in the macOS Keychain under
    /// service=`gemini`, account=`antigravity`. The raw value is prefixed with
    /// `go-keyring-base64:` (go-keyring's encoding) followed by base64-encoded
    /// JSON of the form `{"token":{"access_token":...,"expiry":"<ISO>"},"auth_method":...}`.
    ///
    /// Uses the `/usr/bin/security` CLI rather than `SecItemCopyMatching` so the
    /// app doesn't trigger the macOS keychain access prompt — same approach as
    /// [UsageAPIService.getTokenFromKeychain].
    nonisolated private static func loadKeychainCreds() -> GeminiOAuthCreds? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard var raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix) { raw.removeFirst(prefix.count) }
        guard let decoded = Data(base64Encoded: raw),
              let parsed = try? JSONDecoder().decode(GeminiKeychainCreds.self, from: decoded),
              let token = parsed.token?.accessToken, !token.isEmpty else { return nil }

        let expiry = parsed.token?.expiry.flatMap(parseISODate)
        return GeminiOAuthCreds(accessToken: token, expiry: expiry)
    }

    /// Legacy ~/.gemini/oauth_creds.json — written by the old gemini-cli.
    /// Antigravity does not refresh this file, so it goes stale once the user
    /// switches over, but it is still the right source when only the old CLI
    /// is installed.
    nonisolated private static func loadFileCreds(_ url: URL) -> GeminiOAuthCreds? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GeminiFileCreds.self, from: data),
              let token = decoded.accessToken, !token.isEmpty else { return nil }
        let expiry = decoded.expiryDate.map { Date(timeIntervalSince1970: $0 / 1000) }
        return GeminiOAuthCreds(accessToken: token, expiry: expiry)
    }

    // MARK: - Project discovery

    nonisolated private struct LoadCodeAssistResponse: Decodable {
        let cloudaicompanionProject: String?
    }

    /// Calls LoadCodeAssist to look up the user's `cloudaicompanionProject` id,
    /// which `fetchAvailableModels` requires in the request body. Cached at the
    /// service level after first success so we don't repeat this on every poll.
    nonisolated private static func loadCloudAICompanionProject(token: String) -> String? {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode: Int = 0
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            if let http = response as? HTTPURLResponse { responseCode = http.statusCode }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 12)

        guard responseCode == 200, let data = responseData,
              let decoded = try? JSONDecoder().decode(LoadCodeAssistResponse.self, from: data),
              let project = decoded.cloudaicompanionProject, !project.isEmpty else { return nil }
        return project
    }

    nonisolated private static func parseISODate(_ value: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: value) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: value)
    }
}
