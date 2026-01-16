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
                Toggle("Session % in Menu Bar", isOn: $settings.showMenuBarPercentage)
                Toggle("API Cost in Menu Bar", isOn: $settings.showMenuBarAPICost)
            }

            PricingSection()

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Author", value: "Rui Branco")
            }
        }
        .formStyle(.grouped)
        .frame(width: 320, height: 520)
    }
}

struct PricingSection: View {
    private let pricingService = PricingService.shared

    var body: some View {
        Section("API Pricing (per 1M tokens)") {
            // Show current pricing
            let opus = pricingService.getPricing(for: "opus")
            let sonnet = pricingService.getPricing(for: "sonnet")
            let haiku = pricingService.getPricing(for: "haiku")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Opus:")
                        .font(.caption.bold())
                    Spacer()
                    Text("in $\(opus.inputPerMTok, specifier: "%.0f") / out $\(opus.outputPerMTok, specifier: "%.0f")")
                        .font(.caption.monospacedDigit())
                }
                HStack {
                    Text("Sonnet:")
                        .font(.caption.bold())
                    Spacer()
                    Text("in $\(sonnet.inputPerMTok, specifier: "%.0f") / out $\(sonnet.outputPerMTok, specifier: "%.0f")")
                        .font(.caption.monospacedDigit())
                }
                HStack {
                    Text("Haiku:")
                        .font(.caption.bold())
                    Spacer()
                    Text("in $\(haiku.inputPerMTok, specifier: "%.1f") / out $\(haiku.outputPerMTok, specifier: "%.0f")")
                        .font(.caption.monospacedDigit())
                }
            }
            .foregroundColor(.secondary)

            Button("Edit Pricing Config") {
                openPricingFile()
            }

            Text("Edit ~/.claude/pricing.json to update rates")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func openPricingFile() {
        let path = pricingService.configFilePath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
