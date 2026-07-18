import Foundation
import Combine

@MainActor
final class CodexService: ObservableObject {
    @Published var rateLimits: CodexRateLimitStatus?
    @Published var sessions: [CodexLiveSession] = []
    @Published var isLoading: Bool = true
    @Published var hasCodexInstalled: Bool = false

    private var timer: Timer?
    /// Codex's scan() is the only writer of MenuBarState.codexWeeklyPercent,
    /// and that label is visible whenever showCodexInMenuBar is on — even
    /// while the popover is closed. So we keep a single 5s cadence rather
    /// than throttling by popover visibility; the JSONL parse cache and
    /// libproc cwd lookup make each tick cheap enough that the energy win
    /// from caching alone is sufficient.
    private let scanInterval: TimeInterval = 5
    private let rolloutLookbackDays: Int = 2
    private let maxFileSize: Int = 10 * 1024 * 1024

    /// The authoritative weekly usage comes from the live API, polled less
    /// aggressively than the 5s rollout scan.
    private var usageTimer: Timer?
    private let usageInterval: TimeInterval = 60

    /// Last authoritative value from the live usage API, and the last value we
    /// derived from rollout files. `recomputePublishedRateLimits()` picks between
    /// them: live wins while fresh, rollout is the offline fallback.
    private var liveRateLimits: CodexRateLimitStatus?
    private var lastRolloutRateLimits: CodexRateLimitStatus?

    /// Memoized parsed rollouts keyed by file path. Invalidated when (mtime, size)
    /// changes — unchanged files are reused, which is the dominant win since the
    /// 2-day lookback set rarely changes file-to-file between 5s ticks.
    private var rolloutCache: [String: CachedRollout] = [:]

    nonisolated private struct CachedRollout {
        let mtime: Date
        let size: Int
        let parsed: ParsedRollout
    }

    private var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    func start() {
        Task { await scan() }
        Task { await probeUsage() }
        timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scan()
            }
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: usageInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.probeUsage()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        usageTimer?.invalidate()
        usageTimer = nil
    }

    func refresh() {
        Task { await scan() }
        Task { await probeUsage() }
    }

    /// Triggers an extra refresh when the popover opens so the live-sessions
    /// list renders with fresh data immediately. Cadence is unchanged — see
    /// the `scanInterval` comment for why Codex does not throttle.
    func setPopoverVisible(_ visible: Bool) {
        if visible { Task { await scan() } }
    }

    private func scan() async {
        let root = sessionsRoot
        let installed = FileManager.default.fileExists(atPath: root.path)
        self.hasCodexInstalled = installed

        let cacheSnapshot = rolloutCache
        let result = await Task.detached(priority: .utility) { [lookbackDays = rolloutLookbackDays, capBytes = maxFileSize] in
            CodexService.scanCurrent(
                sessionsRoot: root,
                lookbackDays: lookbackDays,
                maxFileSize: capBytes,
                installed: installed,
                cache: cacheSnapshot
            )
        }.value

        self.rolloutCache = result.updatedCache
        self.sessions = result.sessions
        // The rollout parse is the offline fallback; remember it and let
        // recompute pick between it and the live API value.
        if let limits = result.rateLimits {
            self.lastRolloutRateLimits = limits
        }
        recomputePublishedRateLimits()
        self.isLoading = false
    }

    /// Fetches the authoritative weekly usage from chatgpt.com and prefers it over
    /// the rollout-derived value. Runs off the main actor. On any failure (offline,
    /// expired token, non-200) it leaves the previous live value in place so a brief
    /// blip doesn't wipe the number; a sustained failure ages it out via isStale.
    private func probeUsage() async {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        let fetched = await Task.detached(priority: .utility) {
            CodexService.fetchUsageSync(authURL: authURL)
        }.value
        if let fetched = fetched {
            self.liveRateLimits = fetched
        }
        recomputePublishedRateLimits()
    }

    /// Single source of truth for the published `rateLimits` + menu-bar label.
    /// Live API wins while fresh; otherwise fall back to the last rollout parse;
    /// otherwise keep whatever we last had (shown as a stale placeholder).
    private func recomputePublishedRateLimits() {
        if let live = liveRateLimits, !live.isStale {
            self.rateLimits = live
        } else if let rollout = lastRolloutRateLimits, !rollout.isStale {
            self.rateLimits = rollout
        } else {
            // Both stale (or absent): keep the most recently observed one so the
            // "no recent data · Nh ago" placeholder reports an accurate timestamp.
            self.rateLimits = [liveRateLimits, lastRolloutRateLimits]
                .compactMap { $0 }
                .max(by: { $0.updatedAt < $1.updatedAt }) ?? self.rateLimits
        }

        if let rl = self.rateLimits, !rl.isStale {
            MenuBarState.shared.codexWeeklyPercent = Int(rl.weeklyUsedPercent.rounded())
        } else {
            MenuBarState.shared.codexWeeklyPercent = nil
        }
    }

    // MARK: - Heavy lifting (off-main)

    private struct ScanResult {
        let sessions: [CodexLiveSession]
        let rateLimits: CodexRateLimitStatus?
        let updatedCache: [String: CachedRollout]
    }

    nonisolated private static func scanCurrent(
        sessionsRoot: URL,
        lookbackDays: Int,
        maxFileSize: Int,
        installed: Bool,
        cache: [String: CachedRollout]
    ) -> ScanResult {
        // 1. Find currently running codex processes
        let processes = listCodexProcesses()

        // 2. Find recent rollout files (for token enrichment + rate limits)
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        let rolloutFiles = installed ? recentJsonlFiles(in: sessionsRoot, modifiedAfter: cutoff) : []

        // 3. Scan rollouts ONCE: pick most recent rate_limits + index by cwd / session id.
        //    Reuse cached parse results when (mtime, size) is unchanged.
        var newestRateLimits: (date: Date, status: CodexRateLimitStatus)?
        var rolloutsByCwd: [String: (mtime: Date, totalTokens: Int?)] = [:]
        var rolloutsBySessionId: [String: (mtime: Date, totalTokens: Int?)] = [:]
        var nextCache: [String: CachedRollout] = [:]

        for url in rolloutFiles {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int,
                  size <= maxFileSize else { continue }

            let key = url.path
            let parsed: ParsedRollout
            if let cached = cache[key], cached.size == size, cached.mtime == mtime {
                parsed = cached.parsed
            } else if let fresh = parseRollout(url) {
                parsed = fresh
            } else {
                continue
            }
            nextCache[key] = CachedRollout(mtime: mtime, size: size, parsed: parsed)

            if let rl = parsed.rateLimitsAt {
                if newestRateLimits == nil || rl.date > newestRateLimits!.date {
                    newestRateLimits = rl
                }
            }
            if let cwd = parsed.cwd, !cwd.isEmpty {
                let entry = (mtime: mtime, totalTokens: parsed.totalTokens)
                if let existing = rolloutsByCwd[cwd] {
                    if mtime > existing.mtime { rolloutsByCwd[cwd] = entry }
                } else {
                    rolloutsByCwd[cwd] = entry
                }
            }
            if let sid = parsed.sessionId {
                let entry = (mtime: mtime, totalTokens: parsed.totalTokens)
                rolloutsBySessionId[sid] = entry
            }
        }

        // 4. Build live session list, deduped by cwd (the wrapper + rust binary share cwd)
        var byCwd: [String: CodexLiveSession] = [:]
        for proc in processes {
            let cwd = proc.cwd
            let projectName = cwd.isEmpty
                ? "Codex \(proc.pid)"
                : URL(fileURLWithPath: cwd).lastPathComponent

            // Try to enrich with token data — by session id from `resume <UUID>` first, then by cwd
            var totalTokens: Int?
            if let sid = proc.resumeSessionId, let r = rolloutsBySessionId[sid] {
                totalTokens = r.totalTokens
            } else if !cwd.isEmpty, let r = rolloutsByCwd[cwd] {
                totalTokens = r.totalTokens
            }

            let key = cwd.isEmpty ? "pid-\(proc.pid)" : cwd
            let candidate = CodexLiveSession(
                id: "\(proc.pid)",
                pid: proc.pid,
                projectPath: cwd,
                projectName: projectName,
                memoryMB: proc.memMB,
                totalTokens: totalTokens
            )

            // Keep the highest-memory entry per cwd (rust binary is usually heavier than node wrapper)
            if let existing = byCwd[key] {
                if candidate.memoryMB > existing.memoryMB {
                    byCwd[key] = candidate
                }
            } else {
                byCwd[key] = candidate
            }
        }

        let sessions = Array(byCwd.values).sorted { $0.memoryMB > $1.memoryMB }
        return ScanResult(sessions: sessions, rateLimits: newestRateLimits?.status, updatedCache: nextCache)
    }

    // MARK: - Process detection

    nonisolated private struct CodexProcess {
        let pid: Int32
        let memMB: Int
        let cwd: String
        let resumeSessionId: String?
    }

    nonisolated private static func listCodexProcesses() -> [CodexProcess] {
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
            return parseCodexProcessList(output)
        } catch {
            return []
        }
    }

    nonisolated private static func parseCodexProcessList(_ output: String) -> [CodexProcess] {
        var result: [CodexProcess] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            // Exclude lookalikes and our own scanning machinery
            if line.contains("codex.system")        // Apple cryptex paths
                || line.contains("ClaudeUsageTracker")
                || line.contains("grep ")
                || line.contains("ps -axwwo")
                || line.contains("claude-commands-mcp") {
                continue
            }

            // Two well-defined codex command shapes:
            //   1. `node .../bin/codex ...` (the OpenAI wrapper)
            //   2. `.../@openai/codex.../codex/codex ...` (the spawned rust binary)
            let isWrapper = line.contains("/bin/codex ") || line.hasSuffix("/bin/codex")
            let isRustBin = line.contains("/codex/codex ") || line.hasSuffix("/codex/codex")
            guard isWrapper || isRustBin else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let cols = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count >= 3,
                  let pid = Int32(cols[0]),
                  let rssKB = Int(cols[1]) else { continue }

            let command = String(cols[2])
            let resumeId = extractResumeSessionId(command)
            let cwd = workingDirectory(for: pid)

            result.append(CodexProcess(
                pid: pid,
                memMB: rssKB / 1024,
                cwd: cwd,
                resumeSessionId: resumeId
            ))
        }
        return result
    }

    nonisolated private static func extractResumeSessionId(_ command: String) -> String? {
        // Looks for `resume <uuid>` in args. UUID is hex with dashes.
        let parts = command.split(separator: " ")
        for (idx, part) in parts.enumerated() where part == "resume" && idx + 1 < parts.count {
            let candidate = String(parts[idx + 1])
            if candidate.count >= 32, candidate.contains("-") { return candidate }
        }
        return nil
    }

    nonisolated private static func workingDirectory(for pid: Int32) -> String {
        ProcCwd.of(pid: pid) ?? ""
    }

    // MARK: - Rollout file scanning

    nonisolated private static func recentJsonlFiles(in root: URL, modifiedAfter cutoff: Date) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default

        guard let years = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let currentYear = Calendar.current.component(.year, from: Date())
        let allowed = Set([currentYear, currentYear - 1].map(String.init))

        for yearDir in years where allowed.contains(yearDir.lastPathComponent) {
            guard let months = try? fm.contentsOfDirectory(at: yearDir, includingPropertiesForKeys: nil) else { continue }
            for monthDir in months {
                guard let days = try? fm.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: nil) else { continue }
                for dayDir in days {
                    guard let files = try? fm.contentsOfDirectory(
                        at: dayDir,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for url in files where url.pathExtension == "jsonl" {
                        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                           let mtime = values.contentModificationDate,
                           mtime >= cutoff {
                            result.append(url)
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: - Single-file rollout parser

    nonisolated private struct ParsedRollout {
        let cwd: String?
        let sessionId: String?
        let totalTokens: Int?
        let rateLimitsAt: (date: Date, status: CodexRateLimitStatus)?
    }

    nonisolated private static func parseRollout(_ url: URL) -> ParsedRollout? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()

        var cwd: String?
        var sessionId: String?
        var latestTotal: Int?
        var latestRateLimits: (date: Date, status: CodexRateLimitStatus)?

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = raw.data(using: .utf8),
                  let env = try? decoder.decode(CodexEnvelope.self, from: lineData),
                  let payload = env.payload else { continue }

            switch env.type {
            case "session_meta":
                cwd = payload.cwd
                sessionId = payload.id
            case "event_msg":
                if payload.type == "token_count" {
                    if let t = payload.info?.totalTokenUsage?.totalTokens { latestTotal = t }
                    if let rl = payload.rateLimits {
                        let observed = parseISODate(env.timestamp) ?? Date()
                        if let status = makeRateLimitStatus(from: rl, observedAt: observed) {
                            if latestRateLimits == nil || observed > latestRateLimits!.date {
                                latestRateLimits = (observed, status)
                            }
                        }
                    }
                }
            default: break
            }
        }
        return ParsedRollout(cwd: cwd, sessionId: sessionId, totalTokens: latestTotal, rateLimitsAt: latestRateLimits)
    }

    nonisolated private static func makeRateLimitStatus(from raw: CodexRateLimitsRaw, observedAt: Date) -> CodexRateLimitStatus? {
        // Codex historically reported two windows: a 5h "session" in `primary` and
        // the weekly cap in `secondary`. As of Jul 2026 OpenAI dropped the 5h window
        // — the weekly limit now arrives in `primary` with `secondary` null. Select
        // the weekly window by its size (7 days = 10080 min) rather than by position
        // so both the old and new payload shapes resolve correctly.
        let windows = [raw.primary, raw.secondary]
            .compactMap { $0 }
            .filter { $0.resetsAt != nil }
        // Prefer the exact 7-day window; else the largest window that is at least a
        // day long. Never fall back to a short (e.g. 5h/300min) window — labelling
        // that as "Weekly" would be the misleading number we're trying to avoid.
        let weekly = windows.first(where: { $0.windowMinutes == 10080 })
            ?? windows.filter { ($0.windowMinutes ?? 0) >= 1440 }
                      .max(by: { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) })
        guard let weekly, let reset = weekly.resetsAt,
              let used = weekly.usedPercent else { return nil }
        return CodexRateLimitStatus(
            planType: (raw.planType ?? "").capitalized,
            weeklyUsedPercent: used,
            weeklyResetAt: Date(timeIntervalSince1970: TimeInterval(reset)),
            updatedAt: observedAt
        )
    }

    nonisolated private static func parseISODate(_ value: String?) -> Date? {
        guard let value = value else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: value) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: value)
    }

    // MARK: - Live usage fetch (off-main)

    /// GET chatgpt.com/backend-api/codex/usage using the Codex CLI's own OAuth
    /// access token from ~/.codex/auth.json. This is the same weekly cap shown in
    /// ChatGPT settings. Returns nil (caller keeps the prior value) if creds are
    /// missing, the token has expired, or the request fails.
    nonisolated private static func fetchUsageSync(authURL: URL) -> CodexRateLimitStatus? {
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
              let token = auth.tokens?.accessToken, !token.isEmpty else { return nil }

        // Skip a guaranteed-401 when the JWT has already expired. Codex refreshes
        // this token itself on its next run; we never touch the refresh token.
        if let exp = jwtExpiry(token), exp < Date() { return nil }

        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/usage") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountId = auth.tokens?.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // chatgpt.com sits behind Cloudflare, which 403s requests that don't carry
        // a Codex-shaped User-Agent (URLSession's default "AppName/x CFNetwork/…"
        // gets blocked). Mirror the CLI's `codex_cli_rs/<ver> (…)` string so the
        // edge accepts us. Verified: same request 200s with this UA, 403s without.
        request.setValue(codexUserAgent(), forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode = 0
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            if let http = response as? HTTPURLResponse { responseCode = http.statusCode }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 12)

        guard responseCode == 200, let data = responseData,
              let decoded = try? JSONDecoder().decode(CodexUsageResponse.self, from: data),
              let rl = decoded.rateLimit else { return nil }

        // Select the weekly window (7 days = 604800s). Mirrors the rollout parser:
        // prefer the exact 7-day window, else the largest window at least a day
        // long — never a short window mislabelled as "Weekly". Require a usage
        // percentage so a malformed response doesn't render an authoritative 0%.
        let windows = [rl.primaryWindow, rl.secondaryWindow]
            .compactMap { $0 }
            .filter { $0.resetAt != nil }
        let weekly = windows.first(where: { $0.limitWindowSeconds == 604800 })
            ?? windows.filter { ($0.limitWindowSeconds ?? 0) >= 86400 }
                      .max(by: { ($0.limitWindowSeconds ?? 0) < ($1.limitWindowSeconds ?? 0) })
        guard let weekly, let reset = weekly.resetAt,
              let used = weekly.usedPercent else { return nil }

        return CodexRateLimitStatus(
            planType: (decoded.planType ?? "").capitalized,
            weeklyUsedPercent: used,
            weeklyResetAt: Date(timeIntervalSince1970: TimeInterval(reset)),
            updatedAt: Date()
        )
    }

    /// Builds a Codex-CLI-shaped User-Agent (`codex_cli_rs/<ver> (Macintosh; Darwin
    /// <os>; <arch>)`). Cloudflare rejects requests to chatgpt.com that don't look
    /// like a Codex client. The version is read from ~/.codex/version.json (the
    /// CLI's own update-check cache) with a recent fallback if it's missing.
    nonisolated private static func codexUserAgent() -> String {
        let versionURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/version.json")
        var version = "0.144.5"
        if let data = try? Data(contentsOf: versionURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj["latest_version"] as? String, !v.isEmpty {
            version = v
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return "codex_cli_rs/\(version) (Macintosh; Darwin \(os.majorVersion).\(os.minorVersion).\(os.patchVersion); \(arch))"
    }

    /// Decodes the `exp` claim from a JWT access token without validating the
    /// signature — used only to skip a request we know would 401.
    nonisolated private static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
