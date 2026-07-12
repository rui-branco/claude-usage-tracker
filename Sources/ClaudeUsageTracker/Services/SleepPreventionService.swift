import Foundation
import Combine

/// Controls the system-wide `pmset disablesleep` flag, which keeps the Mac
/// awake even when the lid is closed. Writing the flag requires root: plain
/// power assertions (caffeinate-style) cannot prevent lid-close sleep, and the
/// private IOKit `AppliesOnLidClose` assertion property returns
/// kIOReturnNotPrivileged for non-entitled apps.
///
/// To avoid a password dialog on every toggle, the first change installs a
/// narrowly-scoped sudoers rule (validated with visudo) that allows ONLY the
/// two exact commands `pmset -a disablesleep 1|0` without a password. That
/// single admin prompt also applies the requested change; every toggle after
/// that runs instantly via `sudo -n`.
///
/// The flag is a persistent system setting — it survives app quit and crash —
/// so this service never trusts local state: it re-reads `pmset -g` after
/// every change and whenever the popover opens.
@MainActor
final class SleepPreventionService: ObservableObject {
    static let shared = SleepPreventionService()

    /// Verified system state (`SleepDisabled 1` in `pmset -g`).
    @Published private(set) var isEnabled = false
    /// True while a change + verification round-trip is in flight.
    @Published private(set) var isBusy = false
    /// The state the user just asked for — shown by the switch while the
    /// change is in flight so it doesn't snap back mid-authorization.
    @Published private(set) var pendingTarget: Bool?

    /// Bumped by every setEnabled so refreshes that started before a write
    /// can't land their stale read on top of the verified post-write state.
    private var generation = 0

    private static let sudoersPath = "/etc/sudoers.d/claude-usage-tracker-pmset"

    private init() {
        refreshFromSystem()
    }

    /// Re-read the real flag (readable without privileges). Called at init and
    /// on popover open so the switch mirrors reality even after a crash or an
    /// external `pmset` change.
    func refreshFromSystem() {
        guard !isBusy else { return }
        let startedAt = generation
        Task {
            if let actual = await Self.readSleepDisabled(),
               startedAt == generation, !isBusy {
                isEnabled = actual
            }
        }
    }

    func setEnabled(_ enable: Bool) {
        guard !isBusy, enable != isEnabled else { return }
        isBusy = true
        generation += 1
        pendingTarget = enable
        Task {
            let flag = enable ? "1" : "0"
            // Fast path: the one-time sudoers rule makes this instant and
            // password-free. -n fails immediately while the rule is absent.
            let direct = await Self.run(
                "/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", flag],
                timeout: 15
            )
            if direct?.status != 0 {
                // One admin prompt: install the scoped NOPASSWD rule and apply
                // the requested change in the same authorization.
                _ = await Self.run(
                    "/usr/bin/osascript", ["-e", Self.setupScript(flag: flag)],
                    timeout: 180
                )
            }
            isEnabled = await Self.readSleepDisabled() ?? isEnabled
            pendingTarget = nil
            isBusy = false
        }
    }

    /// AppleScript that (as root, after the native password dialog) installs
    /// the sudoers rule — written to a temp file and checked with visudo so a
    /// malformed file can never reach sudoers.d — then applies the change.
    private static func setupScript(flag: String) -> String {
        // Numeric-UID user spec (#uid) — immune to username quoting issues.
        let rule = "#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let shell = [
            "set -e",
            "umask 077",
            "TMP=$(/usr/bin/mktemp)",
            "trap '/bin/rm -f \"$TMP\"' EXIT",
            "/usr/bin/printf '%s\\n' '\(rule)' > \"$TMP\"",
            "/usr/sbin/visudo -cf \"$TMP\"",
            "/usr/bin/install -m 440 -o root -g wheel \"$TMP\" \(sudoersPath)",
            "/usr/bin/pmset -a disablesleep \(flag)"
        ].joined(separator: "; ")
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    // MARK: - System helpers

    private static func readSleepDisabled() async -> Bool? {
        guard let result = await run("/usr/bin/pmset", ["-g"], timeout: 10),
              result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.first == "SleepDisabled", tokens.count >= 2 {
                return tokens[1] == "1"
            }
        }
        // Key absent → state unknown; caller keeps its current value.
        return nil
    }

    nonisolated private static func run(
        _ path: String, _ arguments: [String], timeout: TimeInterval
    ) async -> (status: Int32, output: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // An abandoned auth dialog would otherwise leave the toggle
                // stuck busy forever.
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: (process.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
