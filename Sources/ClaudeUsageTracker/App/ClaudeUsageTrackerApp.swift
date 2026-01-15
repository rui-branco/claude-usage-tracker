import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var menuBarState = MenuBarState.shared

    var body: some Scene {
        MenuBarExtra {
            AppContentView()
        } label: {
            MenuBarLabel(state: menuBarState)
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView(settings: SettingsService.shared)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var state: MenuBarState
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

@MainActor
class MenuBarState: ObservableObject {
    static let shared = MenuBarState()
    @Published var sessionPercent: Int?
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Initialize app state immediately at launch
        Task { @MainActor in
            await AppState.shared.initialize()
        }
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
