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
    @ObservedObject var codexService: CodexService
    @ObservedObject var geminiService: GeminiService

    // Actual measured content height, written by the GeometryReader below.
    @State private var measuredHeight: CGFloat = 0

    // Cap scroll area to a sensible fraction of available screen height so
    // the popover never overlaps the footer, regardless of how many sessions are live.
    private var maxScrollHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        // Reserve ~220pt for menu bar, header, footer, dividers, and breathing room.
        return max(240, screenHeight - 220)
    }

    private var scrollHeight: CGFloat {
        // Before first measurement, give the ScrollView a tiny seed so content
        // lays out at its natural size (vertical ScrollView proposes unbounded
        // height to content), then shrink to the measured height on next pass.
        let base = measuredHeight > 0 ? measuredHeight : 1
        return min(max(base, 1), maxScrollHeight)
    }

    private var rateLimitsVisible: Bool {
        settings.showRateLimits && (viewModel.rateLimitStatus != nil
            || (settings.showCodexRateLimits && codexService.rateLimits != nil)
            || (settings.showGeminiRateLimits && geminiService.rateLimits != nil))
    }

    private var modelUsageVisible: Bool {
        !viewModel.periodTokensByModel.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content (header removed — popover opens straight into the data)
            ScrollView {
                VStack(spacing: 16) {
                    // Rate Limits (Claude + Codex + Gemini together)
                    if rateLimitsVisible {
                        RateLimitCard(
                            rateLimit: viewModel.rateLimitStatus,
                            codexLimits: settings.showCodexRateLimits ? codexService.rateLimits : nil,
                            geminiLimits: settings.showGeminiRateLimits ? geminiService.rateLimits : nil
                        )
                    }

                    // Usage by model (all-time per-model token totals, incl. Fable 5)
                    if modelUsageVisible {
                        if rateLimitsVisible {
                            SectionSeparator()
                        }
                        ModelUsageCard(models: viewModel.periodTokensByModel)
                    }

                    // Live Sessions (Claude + Codex in one list)
                    if settings.showLiveSessions {
                        if rateLimitsVisible || modelUsageVisible {
                            SectionSeparator()
                        }
                        LiveSessionsCard(
                            sessions: viewModel.liveClaudeSessions,
                            isLoading: viewModel.isLoadingSessions,
                            currentSession: viewModel.sessionCache,
                            orphanedCount: viewModel.orphanedSessionCount,
                            orphanedMemoryMB: viewModel.orphanedMemoryMB,
                            codexSessions: settings.showCodexSessions ? codexService.sessions : [],
                            geminiSessions: settings.showGeminiSessions ? geminiService.sessions : [],
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
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                let h = proxy.size.height
                                if h > 0 { measuredHeight = h }
                            }
                            .onChange(of: proxy.size.height) { newValue in
                                if newValue > 0 { measuredHeight = newValue }
                            }
                    }
                )
            }
            .frame(height: scrollHeight)

            Divider()

            // Footer
            footerView
        }
        .frame(width: 320)
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
