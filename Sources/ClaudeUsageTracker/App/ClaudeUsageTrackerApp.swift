import SwiftUI
import Combine

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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wand.and.stars")

            if settings.showMenuBarPercentage, let percent = state.sessionPercent {
                Text("\(percent)%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
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
                Image(systemName: "wand.and.stars")
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
