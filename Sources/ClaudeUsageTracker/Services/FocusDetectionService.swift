import Foundation
import AppKit
import Combine

@MainActor
final class FocusDetectionService: ObservableObject {
    static let shared = FocusDetectionService()

    @Published var focusedTerminalPath: String?

    private var timer: Timer?

    func startMonitoring() {
        // Check focus every 1 second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.detectFocusedTerminal()
            }
        }
        // Initial check
        detectFocusedTerminal()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func detectFocusedTerminal() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            focusedTerminalPath = nil
            return
        }

        let bundleId = frontApp.bundleIdentifier ?? ""

        // Check if it's a terminal app
        let terminalBundleIds = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "io.alacritty",
            "com.github.wez.wezterm",
            "co.zeit.hyper",
            "com.microsoft.VSCode",  // VS Code integrated terminal
            "com.todesktop.230313mzl4w4u92"  // Cursor
        ]

        guard terminalBundleIds.contains(bundleId) else {
            focusedTerminalPath = nil
            return
        }

        // Get the focused window's working directory using accessibility API
        if let path = getTerminalWorkingDirectory(pid: frontApp.processIdentifier, bundleId: bundleId) {
            focusedTerminalPath = path
        }
    }

    private func getTerminalWorkingDirectory(pid: pid_t, bundleId: String) -> String? {
        // Try using lsof to get the cwd of the foreground process in the terminal
        // First, get the terminal's child processes (the shells/claude processes)

        // For Terminal.app and iTerm2, we can use AppleScript
        if bundleId == "com.apple.Terminal" {
            return getTerminalAppWorkingDirectory()
        } else if bundleId == "com.googlecode.iterm2" {
            return getITermWorkingDirectory()
        }

        // For other terminals, try to find Claude process with matching parent
        return findClaudeProcessCwd(terminalPid: pid)
    }

    private func getTerminalAppWorkingDirectory() -> String? {
        let script = """
        tell application "Terminal"
            if (count of windows) > 0 then
                set frontWindow to front window
                if (count of tabs of frontWindow) > 0 then
                    set currentTab to selected tab of frontWindow
                    set ttyName to tty of currentTab
                    return ttyName
                end if
            end if
        end tell
        return ""
        """

        if let tty = runAppleScript(script), !tty.isEmpty {
            return getCwdFromTty(tty: tty)
        }
        return nil
    }

    private func getITermWorkingDirectory() -> String? {
        let script = """
        tell application "iTerm"
            if (count of windows) > 0 then
                tell current session of current window
                    return tty
                end tell
            end if
        end tell
        return ""
        """

        if let tty = runAppleScript(script), !tty.isEmpty {
            return getCwdFromTty(tty: tty)
        }
        return nil
    }

    private func getCwdFromTty(tty: String) -> String? {
        // Find process using this tty and get its cwd
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "lsof -t \(tty) 2>/dev/null | head -1"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidStr) {
                return getCwdForPid(pid: pid)
            }
        } catch {}

        return nil
    }

    private func getCwdForPid(pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", "\(pid)", "-Fn"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Look for cwd (current working directory)
                let lines = output.components(separatedBy: "\n")
                var foundCwd = false
                for line in lines {
                    if line == "fcwd" {
                        foundCwd = true
                    } else if foundCwd && line.hasPrefix("n") {
                        return String(line.dropFirst())
                    }
                }
            }
        } catch {}

        return nil
    }

    private func findClaudeProcessCwd(terminalPid: pid_t) -> String? {
        // Find claude processes and check if any are children of this terminal
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,ppid,comm"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                for line in lines where line.contains("claude") {
                    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
                    if parts.count >= 2, let pid = Int32(parts[0]) {
                        if let cwd = getCwdForPid(pid: pid) {
                            return cwd
                        }
                    }
                }
            }
        } catch {}

        return nil
    }

    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            if error == nil {
                return result.stringValue
            }
        }
        return nil
    }
}
