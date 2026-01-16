import SwiftUI
import Combine
import AppKit

// Claude icon loaded from bundle PNG
struct ClaudeMenuIcon: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "claude-icon", withExtension: "png"),
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

        // Second menu bar item for API cost (only shows if cost > 0)
        MenuBarExtra {
            AppContentView()
        } label: {
            CostMenuBarLabel()
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
                // Show time until reset only if at 100% AND reset time is in the future
                if let resetAt = state.fiveHourResetAt,
                   state.sessionPercent ?? 0 >= 100,
                   resetAt > currentTime {
                    // At 100% with future reset - show time until reset
                    Text(formatTimeUntil(resetAt))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                } else if let percent = state.sessionPercent {
                    // Normal or reset time passed - show percentage
                    Text("\(percent)%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { time in
            currentTime = time
        }
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

// API cost label (same icon as session)
struct CostMenuBarLabel: View {
    @ObservedObject private var state = MenuBarState.shared
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        if settings.showMenuBarAPICost, let cost = state.apiCost, cost > 0 {
            HStack(spacing: 4) {
                ClaudeMenuIcon()
                Text("$\(Int(cost))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
        }
    }
}

enum MenuBarAPIType {
    case none
    case bedrock
    case claudeAPI
    case mixed  // Both Bedrock and Claude API
    case unknown
}

@MainActor
class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published var sessionPercent: Int?
    @Published var fiveHourResetAt: Date?
    @Published var apiCost: Double?
    @Published var apiType: MenuBarAPIType = .none

    var apiTypeLabel: String {
        switch apiType {
        case .none: return ""
        case .bedrock: return "Bedrock"
        case .claudeAPI: return "API"
        case .mixed: return "API+Bedrock"
        case .unknown: return "API"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
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
                MenuBarView(viewModel: appState.viewModel!, settings: appState.settings)
            } else {
                VStack {
                    ProgressView()
                    Text("Loading...")
                        .font(.caption)
                }
                .frame(width: 200, height: 100)
            }
        }
    }
}

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isLoaded = false
    @Published var viewModel: UsageTrackerViewModel?
    let settings = SettingsService.shared

    private var fileWatcher: FileWatcherService?
    private var processMonitor: ProcessMonitorService?

    func initialize() async {
        guard !isLoaded else { return }

        // Create services
        let fw = FileWatcherService()
        let pm = ProcessMonitorService()

        fileWatcher = fw
        processMonitor = pm

        // Start services
        fw.start()
        pm.startMonitoring()

        // Create view model
        viewModel = UsageTrackerViewModel(fileWatcher: fw, processMonitor: pm)

        // Mark as loaded
        isLoaded = true
    }
}
