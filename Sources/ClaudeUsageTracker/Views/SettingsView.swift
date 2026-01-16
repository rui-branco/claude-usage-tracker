import SwiftUI

enum SettingsTab: String, CaseIterable {
    case account = "Account"
    case general = "General"
    case appearance = "Appearance"
    case data = "Data & Storage"
    case about = "About"
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsService
    @State private var selectedTab: SettingsTab = .account

    var body: some View {
        TabView(selection: $selectedTab) {
            AccountSettingsTab()
                .tabItem {
                    Label("Account", systemImage: "person.circle")
                }
                .tag(SettingsTab.account)

            GeneralSettingsTab(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            AppearanceSettingsTab(settings: settings)
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag(SettingsTab.appearance)

            DataSettingsTab(settings: settings)
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }
                .tag(SettingsTab.data)

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 500, height: 420)
    }
}

// MARK: - Account Tab

struct AccountSettingsTab: View {
    @State private var accountInfo: OAuthAccount?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Profile Section
                GroupBox {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            // Avatar
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [.orange, .red],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 64, height: 64)

                                Text(initials)
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(accountInfo?.displayName ?? "Claude User")
                                    .font(.title3.bold())

                                if let email = accountInfo?.emailAddress {
                                    Text(email)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                if let org = accountInfo?.organizationName {
                                    HStack(spacing: 4) {
                                        Image(systemName: "building.2")
                                            .font(.caption)
                                        Text(org)
                                            .font(.caption)
                                    }
                                    .foregroundColor(.secondary)
                                }
                            }

                            Spacer()
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Profile", systemImage: "person.fill")
                }

                // Subscription Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Claude Max")
                                    .font(.headline)
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.green)
                                    Text("Active Subscription")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("$100")
                                    .font(.title2.bold())
                                Text("/month")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        HStack(spacing: 20) {
                            SubscriptionFeature(icon: "bolt.fill", text: "Unlimited messages")
                            SubscriptionFeature(icon: "cpu", text: "All models")
                            SubscriptionFeature(icon: "clock", text: "Priority access")
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Subscription", systemImage: "creditcard")
                }

                // API Pricing Section
                PricingSection()

                Spacer()
            }
            .padding(20)
        }
        .onAppear { loadAccountInfo() }
    }

    private var initials: String {
        guard let name = accountInfo?.displayName else { return "CU" }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func loadAccountInfo() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = "\(homeDir)/.claude.json"

        if let data = FileManager.default.contents(atPath: configPath),
           let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) {
            accountInfo = config.oauthAccount
        }
    }
}

struct SubscriptionFeature: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.orange)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsService

    var body: some View {
        Form {
            Section {
                Picker("Default Time Frame", selection: $settings.defaultTimeFrame) {
                    Text("Today").tag("1D")
                    Text("7 Days").tag("7D")
                    Text("30 Days").tag("1M")
                    Text("3 Months").tag("3M")
                    Text("All Time").tag("All")
                }
            } header: {
                Label("Startup", systemImage: "power")
            }

            Section {
                Toggle("Enable Auto-Refresh", isOn: $settings.autoRefreshEnabled)

                if settings.autoRefreshEnabled {
                    Picker("Refresh Interval", selection: $settings.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval.rawValue)
                        }
                    }
                }
            } header: {
                Label("Auto Refresh", systemImage: "arrow.clockwise")
            } footer: {
                Text("Auto-refresh updates usage data at the specified interval when the menu bar is open.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Appearance Tab

struct AppearanceSettingsTab: View {
    @ObservedObject var settings: SettingsService

    var body: some View {
        Form {
            Section {
                Toggle("Session % in Menu Bar", isOn: $settings.showMenuBarPercentage)
                Toggle("API Cost in Menu Bar", isOn: $settings.showMenuBarAPICost)
            } header: {
                Label("Menu Bar", systemImage: "menubar.rectangle")
            } footer: {
                Text("API Cost shows your estimated monthly spending from API usage (Bedrock/Claude API).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Live Sessions", isOn: $settings.showLiveSessions)
                Toggle("Rate Limits", isOn: $settings.showRateLimits)
                Toggle("Activity Trend", isOn: $settings.showTrendChart)
                Toggle("Model Breakdown", isOn: $settings.showModelBreakdown)
                Toggle("Recent Projects", isOn: $settings.showRecentProjects)
                Toggle("All Time Stats", isOn: $settings.showAllTimeStats)
            } header: {
                Label("Dashboard Cards", systemImage: "rectangle.grid.2x2")
            }

            Section {
                Toggle("Show Token Counts", isOn: $settings.showTokenCounts)
            } header: {
                Label("Display Options", systemImage: "textformat.size")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Data Tab

struct DataSettingsTab: View {
    @ObservedObject var settings: SettingsService
    @State private var cacheSize: String = "Calculating..."
    @State private var showClearConfirmation = false
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Cache Size")
                    Spacer()
                    Text(cacheSize)
                        .foregroundColor(.secondary)
                }

                Picker("Keep History For", selection: $settings.cacheRetentionDays) {
                    Text("30 Days").tag(30)
                    Text("60 Days").tag(60)
                    Text("90 Days").tag(90)
                    Text("180 Days").tag(180)
                    Text("1 Year").tag(365)
                }

                Button("Clear Cache") {
                    showClearConfirmation = true
                }
                .foregroundColor(.red)
            } header: {
                Label("Cache", systemImage: "internaldrive")
            } footer: {
                Text("Cache stores session history and usage statistics locally.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Export Usage Data") {
                    exportData()
                }

                Button("Reset All Settings") {
                    showResetConfirmation = true
                }
                .foregroundColor(.red)
            } header: {
                Label("Data Management", systemImage: "square.and.arrow.up")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Claude Data Location")
                        .font(.subheadline)
                    HStack {
                        Text("~/.claude/")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Open in Finder") {
                            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
                            NSWorkspace.shared.open(URL(fileURLWithPath: "\(homeDir)/.claude"))
                        }
                        .buttonStyle(.link)
                    }
                }
            } header: {
                Label("File Locations", systemImage: "folder")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            cacheSize = settings.getCacheSize()
        }
        .alert("Clear Cache?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                settings.clearCache()
                cacheSize = settings.getCacheSize()
            }
        } message: {
            Text("This will remove all cached usage data. Your Claude configuration will not be affected.")
        }
        .alert("Reset Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                settings.resetAllSettings()
            }
        } message: {
            Text("This will reset all settings to their default values. Your usage data will not be affected.")
        }
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "claude-usage-export.json"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
                let cachePath = "\(homeDir)/.claude/usage-tracker-cache.json"

                if let data = FileManager.default.contents(atPath: cachePath) {
                    try? data.write(to: url)
                }
            }
        }
    }
}

// MARK: - About Tab

struct AboutSettingsTab: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App Icon and Name
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 64))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .red],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("Claude Usage Tracker")
                        .font(.title.bold())

                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)

                Divider()
                    .padding(.horizontal, 40)

                // Description
                Text("Track your Claude API usage, monitor rate limits, and analyze your productivity with detailed statistics and insights.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                // Links
                GroupBox {
                    VStack(spacing: 12) {
                        LinkRow(icon: "ladybug", title: "Report Issue", url: "https://github.com/rui-branco/claude-usage-tracker/issues")
                        Divider()
                        LinkRow(icon: "star", title: "Star on GitHub", url: "https://github.com/rui-branco/claude-usage-tracker")
                    }
                    .padding(4)
                } label: {
                    Label("Resources", systemImage: "link")
                }
                .padding(.horizontal, 20)

                // Credits
                GroupBox {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Created by")
                            Spacer()
                            Text("Rui Branco")
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Text("Built with")
                            Spacer()
                            Text("SwiftUI")
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Text("License")
                            Spacer()
                            Text("MIT")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .padding(4)
                } label: {
                    Label("Credits", systemImage: "heart")
                }
                .padding(.horizontal, 20)

                Text("© 2025 Rui Branco. All rights reserved.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
        }
    }
}

struct LinkRow: View {
    let icon: String
    let title: String
    let url: String

    var body: some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.orange)
                    .frame(width: 24)
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pricing Section (Moved from original)

struct PricingSection: View {
    private let pricingService = PricingService.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Anthropic API & AWS Bedrock (same rates)")
                    .font(.caption2)
                    .foregroundColor(.secondary)

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

                let lastUpdated = pricingService.lastUpdated
                if !lastUpdated.isEmpty {
                    Text("Updated: \(lastUpdated)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("API Pricing (per 1M tokens)", systemImage: "dollarsign")
        }
    }
}
