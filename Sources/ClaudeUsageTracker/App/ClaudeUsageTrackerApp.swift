import SwiftUI
import Combine
import AppKit

// Claude icon loaded from bundle PNG
struct ClaudeMenuIcon: View {
    var body: some View {
        if let url = ResourceLoader.url(forResource: "claude-icon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            nsImage.size = NSSize(width: 16, height: 16)
            return AnyView(Image(nsImage: nsImage))
        } else {
            return AnyView(Image(systemName: "asterisk"))
        }
    }
}


@main
struct ClaudeUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Main menu bar item with icon and session %
        MenuBarExtra {
            AppContentView()
        } label: {
            SessionMenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView(settings: SettingsService.shared)
        }
    }
}

// Session percentage label with icon
struct SessionMenuBarLabel: View {
    @ObservedObject private var state = MenuBarState.shared
    @ObservedObject private var settings = SettingsService.shared
    @State private var currentTime = Date()

    var body: some View {
        HStack(spacing: 4) {
            ClaudeMenuIcon()

            if settings.showMenuBarPercentage {
                let codexVisible = settings.showCodexInMenuBar && state.codexWeeklyPercent != nil
                let geminiVisible = settings.showGeminiInMenuBar && state.geminiSessionPercent != nil
                let grokVisible = settings.showGrokInMenuBar && state.grokWeeklyPercent != nil
                let showResetCountdown = (state.sessionPercent ?? 0) >= 100
                    && state.fiveHourResetAt.map { $0 > currentTime } ?? false
                    && state.weeklyPercent == nil
                    && !codexVisible
                    && !geminiVisible
                    && !grokVisible

                if showResetCountdown, let resetAt = state.fiveHourResetAt {
                    Text(formatTimeUntil(resetAt))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                } else {
                    Text(buildLabel(claudeSession: state.sessionPercent,
                                    claudeWeekly: state.weeklyPercent,
                                    codex: codexVisible ? state.codexWeeklyPercent : nil,
                                    gemini: geminiVisible ? state.geminiSessionPercent : nil,
                                    grok: grokVisible ? state.grokWeeklyPercent : nil))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { time in
            currentTime = time
        }
    }

    /// macOS MenuBarExtra labels render most reliably as a single Text — colored
    /// substrings via AttributedString instead of an HStack of separate Texts.
    private func buildLabel(
        claudeSession: Int?,
        claudeWeekly: Int?,
        codex: Int?,
        gemini: Int?,
        grok: Int?
    ) -> AttributedString {
        var attr = AttributedString()
        var firstWritten = false

        // Claude: compact session/weekly when both available, otherwise just one
        if let session = claudeSession, let weekly = claudeWeekly {
            var c = AttributedString("\(session)%/\(weekly)%")
            c.foregroundColor = .orange
            attr += c
            firstWritten = true
        } else if let session = claudeSession {
            var c = AttributedString("\(session)%")
            c.foregroundColor = .orange
            attr += c
            firstWritten = true
        } else if let weekly = claudeWeekly {
            var c = AttributedString("\(weekly)%")
            c.foregroundColor = .orange
            attr += c
            firstWritten = true
        }
        if let codex = codex {
            if firstWritten {
                var sep = AttributedString(" · ")
                sep.foregroundColor = .secondary
                attr += sep
            }
            var x = AttributedString("\(codex)%")
            x.foregroundColor = .green
            attr += x
            firstWritten = true
        }
        if let gemini = gemini {
            if firstWritten {
                var sep = AttributedString(" · ")
                sep.foregroundColor = .secondary
                attr += sep
            }
            var g = AttributedString("\(gemini)%")
            g.foregroundColor = .blue
            attr += g
            firstWritten = true
        }
        if let grok = grok {
            if firstWritten {
                var sep = AttributedString(" · ")
                sep.foregroundColor = .secondary
                attr += sep
            }
            var k = AttributedString("\(grok)%")
            k.foregroundColor = .primary
            attr += k
        }
        return attr
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "0m" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

@MainActor
class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published var sessionPercent: Int?
    @Published var weeklyPercent: Int?
    @Published var fiveHourResetAt: Date?
    @Published var codexWeeklyPercent: Int?
    @Published var geminiSessionPercent: Int?
    @Published var grokWeeklyPercent: Int?
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Initialize analytics
        AnalyticsService.shared.initialize()
        AnalyticsService.shared.trackAppLaunched()

        // Initialize app state immediately at launch
        Task { @MainActor in
            await AppState.shared.initialize()
        }

        // Check for updates on launch (if enabled, throttled to every 24 hours)
        Task { @MainActor in
            let settings = SettingsService.shared
            if settings.checkForUpdatesAutomatically {
                let shouldCheck = settings.lastUpdateCheck == nil ||
                    Date().timeIntervalSince(settings.lastUpdateCheck!) > 86400
                if shouldCheck {
                    let _ = await UpdateService.shared.checkForUpdates()
                    settings.lastUpdateCheck = Date()
                }
            }
        }

        // Observe window appearances to configure settings window
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.configureSettingsWindow(notification)
        }
    }

    private func configureSettingsWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Settings tab names from SettingsTab enum
        let settingsTabTitles = ["Account", "General", "Appearance", "Data & Storage", "About"]

        // Check if this is the settings window (by title matching a tab name)
        if settingsTabTitles.contains(window.title) ||
           window.identifier?.rawValue.contains("settings") == true {
            // Remove minimize and zoom buttons, keep only close
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            // Prevent resizing
            window.styleMask.remove(.resizable)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AnalyticsService.shared.trackAppTerminated()
    }
}

struct AppContentView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        Group {
            if appState.isLoaded {
                MenuBarView(
                    viewModel: appState.viewModel!,
                    settings: appState.settings,
                    codexService: appState.codexService!,
                    geminiService: appState.geminiService!,
                    grokService: appState.grokService!
                )
            } else {
                VStack {
                    ProgressView()
                    Text("Loading...")
                        .font(.caption)
                }
                .frame(width: 200, height: 100)
            }
        }
        // AppContentView is only materialized inside the MenuBarExtra
        // content closure, so its appear/disappear hooks act as a pragmatic
        // proxy for popover open/close. SwiftUI may re-create the view in
        // edge cases, but the worst outcome is an extra scan or a missed
        // throttle window — the scanners themselves stay correct.
        .onAppear { appState.setPopoverVisible(true) }
        .onDisappear { appState.setPopoverVisible(false) }
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isLoaded = false
    @Published var viewModel: UsageTrackerViewModel?
    @Published var codexService: CodexService?
    @Published var geminiService: GeminiService?
    @Published var grokService: GrokService?
    let settings = SettingsService.shared

    private var fileWatcher: FileWatcherService?
    private var processMonitor: ProcessMonitorService?

    func initialize() async {
        guard !isLoaded else { return }

        // Create services
        let fw = FileWatcherService()
        let pm = ProcessMonitorService()
        let codex = CodexService()
        let gemini = GeminiService()
        let grok = GrokService()

        fileWatcher = fw
        processMonitor = pm
        codexService = codex
        geminiService = gemini
        grokService = grok

        // Start services
        fw.start()
        pm.startMonitoring()
        codex.start()
        gemini.start()
        grok.start()

        // Create view model
        viewModel = UsageTrackerViewModel(fileWatcher: fw, processMonitor: pm)

        // Mark as loaded
        isLoaded = true
    }

    /// Propagate popover state so scanners that do not drive visible menu-bar
    /// data (ProcessMonitor, Gemini) can back off to 30s while hidden. Codex's
    /// scanner stays on 5s because it publishes the menu-bar % directly — its
    /// setPopoverVisible only triggers an extra refresh on open.
    func setPopoverVisible(_ visible: Bool) {
        processMonitor?.setPopoverVisible(visible)
        codexService?.setPopoverVisible(visible)
        geminiService?.setPopoverVisible(visible)
        grokService?.setPopoverVisible(visible)
    }
}
