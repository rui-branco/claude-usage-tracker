import SwiftUI
import AppKit

// Fade-gradient hairline used to separate major sections.
struct SectionSeparator: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, Color.secondary.opacity(0.28), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .padding(.vertical, 4)
    }
}

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
                VStack(spacing: 16) {
                    // Rate Limits
                    if settings.showRateLimits, let rateLimit = viewModel.rateLimitStatus {
                        RateLimitCard(rateLimit: rateLimit)
                    }

                    if settings.showRateLimits && settings.showLiveSessions {
                        SectionSeparator()
                    }

                    // Live Sessions
                    if settings.showLiveSessions {
                        LiveSessionsCard(
                            sessions: viewModel.liveClaudeSessions,
                            isLoading: viewModel.isLoadingSessions,
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
                }
                .padding()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 520)

            Divider()

            // Footer
            footerView
        }
        .frame(width: 320)
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
        AnalyticsService.shared.trackSettingsOpened()

        NSApp.activate(ignoringOtherApps: true)

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

        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
