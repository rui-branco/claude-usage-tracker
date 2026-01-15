import Foundation
import Combine

struct LiveClaudeSession: Identifiable, Equatable {
    let id: String
    let pid: Int32
    let projectPath: String
    let projectName: String
    let cpuUsage: Double
    let memoryMB: Int
    var tokens: Int?
    var cost: Double?
    var isBedrock: Bool = false
    var contextPercent: Double?
    var modelName: String?
    var isRealtime: Bool = false  // Has real-time data from session cache
}

@MainActor
final class ProcessMonitorService: ObservableObject {
    @Published var liveSessions: [LiveClaudeSession] = []
    @Published var lastScan: Date?
    @Published var isLoading = true

    private var timer: Timer?

    init() {}

    func startMonitoring() {
        // Initial scan
        Task {
            await scanInBackground()
        }

        // Scan every 5 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                await self?.scanInBackground()
            }
        }
    }

    private func scanInBackground() async {
        let sessions = await Task.detached(priority: .utility) {
            Self.getRunningClaudeSessions()
        }.value

        self.liveSessions = sessions
        self.lastScan = Date()
        self.isLoading = false
    }

    nonisolated private static func getRunningClaudeSessions() -> [LiveClaudeSession] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["aux"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()

            // IMPORTANT: Read data BEFORE waitUntilExit to avoid deadlock
            // when the pipe buffer fills up
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                return []
            }

            return parseProcessList(output)
        } catch {
            return []
        }
    }

    nonisolated private static func parseProcessList(_ output: String) -> [LiveClaudeSession] {
        var sessions: [LiveClaudeSession] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            // Match lines ending with "claude" (the CLI process)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("claude") || trimmed.contains("/claude ") else { continue }
            guard !line.contains("ClaudeUsageTracker") &&
                  !line.contains("Claude.app") &&
                  !line.contains("grep") else { continue }

            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 11 else { continue }

            guard let pid = Int32(components[1]),
                  let cpu = Double(components[2]),
                  let memKB = Int(components[5]) else { continue }


            // Get project path from working directory
            let projectPath = getWorkingDirectory(for: pid)
            let projectName = projectPath.isEmpty ? "Claude \(pid)" : URL(fileURLWithPath: projectPath).lastPathComponent

            let session = LiveClaudeSession(
                id: "\(pid)",
                pid: pid,
                projectPath: projectPath,
                projectName: projectName,
                cpuUsage: cpu,
                memoryMB: memKB / 1024
            )
            sessions.append(session)
        }

        return sessions.sorted { $0.cpuUsage > $1.cpuUsage }
    }

    nonisolated private static func getWorkingDirectory(for pid: Int32) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", "\(pid)", "-Fn"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return "" }

            // Parse lsof output - look for 'cwd' followed by path
            let lines = output.components(separatedBy: "\n")
            var foundCwd = false
            for line in lines {
                if line == "fcwd" {
                    foundCwd = true
                } else if foundCwd && line.hasPrefix("n") {
                    return String(line.dropFirst()) // Remove 'n' prefix
                }
            }
        } catch {}

        return ""
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func killSession(_ session: LiveClaudeSession) {
        // Use shell to kill process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "kill -9 \(session.pid)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Failed to kill process: \(error)")
        }

        // Refresh after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await scanInBackground()
        }
    }
}
