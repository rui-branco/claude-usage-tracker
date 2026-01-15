import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsService

    var body: some View {
        Form {
            Section("Auto Refresh") {
                Toggle("Enable auto-refresh", isOn: $settings.autoRefreshEnabled)

                if settings.autoRefreshEnabled {
                    Picker("Interval", selection: $settings.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval.rawValue)
                        }
                    }
                }
            }

            Section("Visibility") {
                Toggle("Live Sessions", isOn: $settings.showLiveSessions)
                Toggle("Rate Limits", isOn: $settings.showRateLimits)
                Toggle("Activity Trend", isOn: $settings.showTrendChart)
                Toggle("Model Breakdown", isOn: $settings.showModelBreakdown)
                Toggle("Recent Projects", isOn: $settings.showRecentProjects)
                Toggle("All Time Stats", isOn: $settings.showAllTimeStats)
            }

            Section("Display") {
                Toggle("Compact Mode", isOn: $settings.compactMode)
                Toggle("Session % in Menu Bar", isOn: $settings.showMenuBarPercentage)
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Author", value: "Rui Branco")
            }
        }
        .formStyle(.grouped)
        .frame(width: 320, height: 420)
    }
}
