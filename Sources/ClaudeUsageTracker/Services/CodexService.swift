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
        timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scan()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task { await scan() }
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
        // Keep last known rate limits if this scan didn't find newer ones
        if let limits = result.rateLimits {
            self.rateLimits = limits
        }
        // Publish the weekly % to the menu bar label, but only if data is still in-window.
        if let limits = self.rateLimits, !limits.secondaryIsStale {
            MenuBarState.shared.codexWeeklyPercent = Int(limits.secondaryUsedPercent.rounded())
        } else {
            MenuBarState.shared.codexWeeklyPercent = nil
        }
        self.isLoading = false
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
        guard let p = raw.primary, let s = raw.secondary,
              let pReset = p.resetsAt, let sReset = s.resetsAt else { return nil }
        return CodexRateLimitStatus(
            planType: (raw.planType ?? "").capitalized,
            primaryUsedPercent: p.usedPercent ?? 0,
            secondaryUsedPercent: s.usedPercent ?? 0,
            primaryResetAt: Date(timeIntervalSince1970: TimeInterval(pReset)),
            secondaryResetAt: Date(timeIntervalSince1970: TimeInterval(sReset)),
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
}
