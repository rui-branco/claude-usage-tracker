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
                || line.contains("Antigravity")             // Google Antigravity wrapper
                || line.contains("gemini-cli-mcp")
                || line.contains("forge-deck") {
                continue
            }

            // Gemini CLI is installed via npm. Match either the wrapper bin/gemini
            // or a node process whose command line contains gemini-cli's entrypoint.
            let isWrapper = line.contains("/bin/gemini ") || line.hasSuffix("/bin/gemini")
            let isNodeGemini = line.contains("node") && (
                line.contains("@google/gemini-cli") ||
                line.contains("/gemini-cli/") ||
                line.contains("/gemini/dist/")
            )
            guard isWrapper || isNodeGemini else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let cols = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count >= 3,
                  let pid = Int32(cols[0]),
                  let rssKB = Int(cols[1]) else { continue }

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
        guard FileManager.default.fileExists(atPath: credsURL.path),
              let credData = try? Data(contentsOf: credsURL),
              let creds = try? JSONDecoder().decode(GeminiOAuthCreds.self, from: credData),
              let token = creds.accessToken, !token.isEmpty else { return QuotaResult(status: nil, projectId: nil) }

        // Skip when the token has clearly expired — avoid a guaranteed 401.
        if let expiryMs = creds.expiryDate {
            let expiry = Date(timeIntervalSince1970: expiryMs / 1000)
            if expiry < Date() { return QuotaResult(status: nil, projectId: nil) }
        }

        // Discover a GCP project on first call. Without one, the quota endpoint
        // returns placeholder fractions (1.0 across the board); with one, real per-model usage.
        var discoveredProject: String?
        let activeProject: String?
        if let projectId = projectId {
            activeProject = projectId
        } else if let found = listFirstActiveProject(token: token) {
            discoveredProject = found
            activeProject = found
        } else {
            activeProject = nil
        }

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            return QuotaResult(status: nil, projectId: discoveredProject)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let activeProject = activeProject {
            // JSON-encode to handle any unusual characters in the project ID safely.
            let body: [String: String] = ["project": activeProject]
            request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }

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
              let decoded = try? JSONDecoder().decode(GeminiQuotaResponse.self, from: data),
              let buckets = decoded.buckets, !buckets.isEmpty else {
            return QuotaResult(status: nil, projectId: discoveredProject)
        }

        // Collapse to one entry per model: keep the bucket with the LOWEST remaining fraction
        // (= the worst-case constraint for that model).
        var byModel: [String: (fraction: Double, resetTime: String?)] = [:]
        for bucket in buckets {
            guard let model = bucket.modelId, let fraction = bucket.remainingFraction else { continue }
            if let existing = byModel[model] {
                if fraction < existing.fraction { byModel[model] = (fraction, bucket.resetTime) }
            } else {
                byModel[model] = (fraction, bucket.resetTime)
            }
        }
        guard !byModel.isEmpty else { return QuotaResult(status: nil, projectId: discoveredProject) }

        let perModelAll: [(model: String, usedPercent: Double, resetAt: Date?, resetKey: String)] = byModel
            .sorted { $0.key < $1.key }
            .map { entry in
                (model: entry.key,
                 usedPercent: max(0, min(100, (1.0 - entry.value.fraction) * 100)),
                 resetAt: entry.value.resetTime.flatMap(parseISODate),
                 resetKey: entry.value.resetTime ?? "")
            }

        // Models that share a quota pool return identical (usedPercent, resetTime). Group
        // by that signature and keep the newest variant — preview models sort after stable
        // ones lexicographically ("2.5-pro" < "3-pro-preview" < "3.1-pro-preview"), so the
        // last-sorted name in each pool is the one to show.
        var pooled: [String: (model: String, usedPercent: Double, resetAt: Date?)] = [:]
        for entry in perModelAll {
            let signature = "\(Int(entry.usedPercent.rounded()))|\(entry.resetKey)"
            let candidate = (model: entry.model, usedPercent: entry.usedPercent, resetAt: entry.resetAt)
            if let existing = pooled[signature] {
                if entry.model > existing.model { pooled[signature] = candidate }
            } else {
                pooled[signature] = candidate
            }
        }
        let deduped = pooled.values.sorted { $0.model < $1.model }

        // Only show models the user has actually hit (display rounds to 0% below 0.5%).
        // Fall back to the worst pool overall if nothing is used so the section never disappears.
        let used = deduped.filter { $0.usedPercent >= 0.5 }
        let perModel: [(model: String, usedPercent: Double, resetAt: Date?)]
        if used.isEmpty {
            perModel = deduped.max(by: { $0.usedPercent < $1.usedPercent }).map { [$0] } ?? []
        } else {
            perModel = used
        }

        // Most-pressured model drives the menu bar gauge.
        let worst = perModel.max(by: { $0.usedPercent < $1.usedPercent }) ?? perModel.first!

        let status = GeminiRateLimitStatus(
            model: worst.model,
            usedPercent: worst.usedPercent,
            resetAt: worst.resetAt,
            updatedAt: Date(),
            perModel: perModel
        )
        return QuotaResult(status: status, projectId: discoveredProject)
    }

    // MARK: - GCP project discovery

    nonisolated private struct CloudProjectsResponse: Decodable {
        let projects: [CloudProject]?
    }
    nonisolated private struct CloudProject: Decodable {
        let projectId: String?
        let lifecycleState: String?
    }

    /// Fetches the first ACTIVE GCP project the user has access to. Empirically every
    /// project returns the same quota numbers (quota is per-user, not per-project),
    /// so picking any active one is fine.
    nonisolated private static func listFirstActiveProject(token: String) -> String? {
        guard let url = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

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
              let decoded = try? JSONDecoder().decode(CloudProjectsResponse.self, from: data) else { return nil }
        return decoded.projects?
            .first(where: { ($0.lifecycleState ?? "").uppercased() == "ACTIVE" && !($0.projectId ?? "").isEmpty })?
            .projectId
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
