import SwiftUI
import AppKit

// Claude icon for header - loaded from bundle PNG with orange tint
struct ClaudeHeaderIcon: View {
    private var iconImage: NSImage? {
        guard let url = ResourceLoader.url(forResource: "claude-icon", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url) else { return nil }
        nsImage.size = NSSize(width: 18, height: 18)
        nsImage.isTemplate = true  // Makes it tintable
        return nsImage
    }

    var body: some View {
        if let nsImage = iconImage {
            Image(nsImage: nsImage)
                .foregroundColor(.orange)
        } else {
            Image(systemName: "asterisk")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.orange)
        }
    }
}

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
                    // API Cost Summary (shows when loading or when user has API/Bedrock projects)
                    if viewModel.showAPICostCard {
                        APICostCard(breakdown: viewModel.apiCostBreakdown, isLoading: viewModel.isLoadingAPICosts)
                    }

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
                            orphanedCount: viewModel.orphanedSessionCount,
                            orphanedMemoryMB: viewModel.orphanedMemoryMB,
                            onKillSession: { session in
                                viewModel.killSession(session)
                            },
                            onKillOrphaned: {
                                viewModel.killOrphanedSessions()
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
                            VStack(spacing: 6) {
                                ForEach(viewModel.periodTokensByModel, id: \.name) { model in
                                    HStack {
                                        Circle()
                                            .fill(model.color)
                                            .frame(width: 8, height: 8)
                                        Text(model.displayName)
                                            .font(.caption)
                                        Spacer()
                                        Text(viewModel.formatTokenCount(model.tokens))
                                            .font(.caption.monospacedDigit())
                                        Text("(\(formatAPICost(model.apiCost)))")
                                            .font(.caption2.monospacedDigit())
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
                            allSessions: viewModel.liveSessions,
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
        .frame(width: 320, height: 580)
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ClaudeHeaderIcon()
                    Text("Claude Usage Tracker")
                        .font(.headline)
                }
                if let updated = viewModel.lastUpdated {
                    Text("Updated \(updated, formatter: timeFormatter)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Plan badge
            if let rateLimit = viewModel.rateLimitStatus {
                Text(rateLimit.planName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
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

    private func formatAPICost(_ cost: Double) -> String {
        if cost < 0.01 { return "<$0.01" }
        if cost < 1 { return String(format: "$%.2f", cost) }
        return String(format: "$%.0f", cost)
    }

    private func openSettings() {
        AnalyticsService.shared.trackSettingsOpened()

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
