import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: UsageTrackerViewModel
    @ObservedObject var settings: SettingsService

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 12) {
                    // Rate Limits (at top for subscription users)
                    if settings.showRateLimits, let rateLimit = viewModel.rateLimitStatus {
                        RateLimitCard(rateLimit: rateLimit)
                    }

                    // Live Sessions
                    if settings.showLiveSessions {
                        LiveSessionsCard(
                            sessions: viewModel.liveClaudeSessions,
                            isLoading: viewModel.isLoadingSessions,
                            isSubscription: viewModel.rateLimitStatus != nil,
                            currentSession: viewModel.sessionCache,
                            onKillSession: { session in
                                viewModel.killSession(session)
                            }
                        )
                    }

                    // Period Stats with Time Picker
                    periodStatsCard

                    // Trend Chart
                    if settings.showTrendChart && !viewModel.filteredActivity.isEmpty {
                        CollapsibleCard(
                            title: "Activity Trend",
                            icon: "chart.line.uptrend.xyaxis",
                            count: nil,
                            isExpanded: $viewModel.isTrendExpanded
                        ) {
                            TrendChartView(data: viewModel.filteredActivity)
                                .frame(height: 80)
                        }
                    }

                    // Model Breakdown
                    if settings.showModelBreakdown && !viewModel.periodTokensByModel.isEmpty {
                        CollapsibleCard(
                            title: "Models",
                            icon: "cpu",
                            count: viewModel.periodTokensByModel.count,
                            isExpanded: $viewModel.isModelsExpanded
                        ) {
                            VStack(spacing: 8) {
                                ForEach(viewModel.periodTokensByModel, id: \.name) { model in
                                    HStack {
                                        Circle()
                                            .fill(model.color)
                                            .frame(width: 10, height: 10)
                                        Text(model.displayName)
                                            .font(.caption)
                                        Spacer()
                                        Text(viewModel.formatTokenCount(model.tokens))
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    // Recent Projects History
                    if settings.showRecentProjects {
                        HistorySessionsCard(
                            sessions: viewModel.recentSessions,
                            formatTokens: viewModel.formatTokenCount,
                            formatCost: viewModel.formatCost,
                            isExpanded: $viewModel.isHistoryExpanded
                        )
                    }

                    // All Time Totals
                    if settings.showAllTimeStats && viewModel.selectedTimeFrame != .all {
                        allTimeSection
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            footerView
        }
        .frame(width: 320, height: settings.compactMode ? 480 : 580)
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.accentColor)
                    Text("Claude Usage")
                        .font(.headline)
                }
                if let updated = viewModel.lastUpdated {
                    Text("Updated \(updated, formatter: timeFormatter)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Plan badge and status
            HStack(spacing: 6) {
                if let rateLimit = viewModel.rateLimitStatus {
                    Text(rateLimit.planName)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
                Circle()
                    .fill(viewModel.statusColor)
                    .frame(width: 10, height: 10)
            }
        }
        .padding()
    }

    private var periodStatsCard: some View {
        VStack(spacing: 8) {
            // Time picker integrated
            TimeFramePicker(selection: $viewModel.selectedTimeFrame)

            Divider()
                .padding(.vertical, 4)

            HStack {
                Text(viewModel.formatTokenCount(viewModel.periodTokens) + " tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.accentColor)
                Spacer()
            }

            HStack(spacing: 0) {
                StatItem(
                    title: "Messages",
                    value: "\(viewModel.periodMessages)",
                    icon: "message.fill"
                )
                Divider().frame(height: 40)
                StatItem(
                    title: "Sessions",
                    value: "\(viewModel.periodSessions)",
                    icon: "terminal.fill"
                )
                Divider().frame(height: 40)
                StatItem(
                    title: "Tools",
                    value: "\(viewModel.periodToolCalls)",
                    icon: "wrench.fill"
                )
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
    }

    private var allTimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All Time")
                .font(.subheadline.bold())

            HStack {
                Label("\(viewModel.totalSessions)", systemImage: "folder")
                    .font(.caption)
                Spacer()
                Text("Sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Label("\(viewModel.totalMessages)", systemImage: "message")
                    .font(.caption)
                Spacer()
                Text("Messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Label(viewModel.formatTokenCount(viewModel.totalTokens), systemImage: "textformat.123")
                    .font(.caption)
                Spacer()
                Text("Total Tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
    }

    private var footerView: some View {
        HStack {
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit", systemImage: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gear")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            if !settings.autoRefreshEnabled {
                Spacer()
                    .frame(width: 16)

                Button(action: { viewModel.refresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }

    private func openSettings() {
        // Try multiple approaches for opening settings
        NSApp.activate(ignoringOtherApps: true)

        // Approach 1: Keyboard shortcut simulation
        if let mainMenu = NSApp.mainMenu,
           let appMenuItem = mainMenu.item(at: 0),
           let appMenu = appMenuItem.submenu {
            for item in appMenu.items {
                if item.title.contains("Settings") || item.title.contains("Preferences") {
                    _ = item.target?.perform(item.action, with: item)
                    return
                }
            }
        }

        // Approach 2: Direct selector
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
