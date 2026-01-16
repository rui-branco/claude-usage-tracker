import SwiftUI

struct LiveSessionsCard: View {
    let sessions: [LiveClaudeSession]
    var isLoading: Bool = false
    var isSubscription: Bool = true  // true = show tokens, false = show cost (Bedrock/API)
    var currentSession: SessionCache?  // Real-time session data
    var onKillSession: ((LiveClaudeSession) -> Void)?

    @State private var sessionToKill: LiveClaudeSession?
    @State private var killingSession: LiveClaudeSession?
    @State private var hoveredSession: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(Color.green.opacity(0.5), lineWidth: 2)
                                .scaleEffect(1.5)
                        )
                    Text("Live Sessions")
                        .font(.subheadline.bold())
                }
                Spacer()
                Text("\(sessions.count) active")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Scanning sessions...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if sessions.isEmpty {
                HStack {
                    Image(systemName: "moon.zzz")
                        .foregroundColor(.secondary)
                    Text("No active Claude sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(sessions) { session in
                    if killingSession?.id == session.id {
                        // Killing state - same structure as normal row
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 6, height: 6)
                                    Text(session.projectName)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                Text("Stopping...")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    } else if sessionToKill?.id == session.id {
                        // Inline confirmation - same height as normal row
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stop \(session.projectName)?")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            Spacer()
                            Button("Yes") {
                                killingSession = session
                                sessionToKill = nil
                                onKillSession?(session)
                                // Clear killing state after delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    killingSession = nil
                                }
                            }
                            .font(.caption.bold())
                            .foregroundColor(.red)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)

                            Button("No") {
                                sessionToKill = nil
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    } else {
                        VStack(spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 6, height: 6)
                                        Text(session.projectName)
                                            .font(.caption)
                                            .lineLimit(1)
                                        // Show model name if available
                                        if let modelName = session.modelName {
                                            Text("(\(modelName))")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    // Show API/Sub indicator only (no cost)
                                    if session.isBedrock {
                                        Text("API")
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .foregroundColor(.orange)
                                            .cornerRadius(3)
                                    } else if isSubscription {
                                        Text("Sub")
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .foregroundColor(.blue)
                                            .cornerRadius(3)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    // Show tokens
                                    if let tokens = session.tokens, tokens > 0 {
                                        Text(formatTokens(tokens))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("— tok")
                                            .font(.caption)
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }
                                    // Always show memory
                                    Text("\(session.memoryMB) MB")
                                        .font(.caption2)
                                        .foregroundColor(.secondary.opacity(0.7))
                                }
                                // X button - animated, only shows on hover
                                if hoveredSession == session.id {
                                    Button(action: {
                                        sessionToKill = session
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red.opacity(0.7))
                                            .font(.system(size: 14))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Stop this session")
                                    .transition(.opacity.combined(with: .scale))
                                }
                            }
                            // Context window progress bar (real-time data)
                            if let contextPercent = session.contextPercent {
                                ContextProgressBar(percent: contextPercent)
                            }
                        }
                        .padding(.vertical, 2)
                        .onHover { isHovered in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                hoveredSession = isHovered ? session.id : nil
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(sessions.isEmpty ? Color.clear : Color.green.opacity(0.3), lineWidth: 1)
        )
    }

    private func formatTokens(_ count: Int) -> String {
        switch count {
        case 0..<1000: return "\(count) tok"
        case 1000..<1_000_000: return String(format: "%.1fK tok", Double(count) / 1000)
        default: return String(format: "%.1fM tok", Double(count) / 1_000_000)
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.3f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}

// Context window progress bar for real-time session data
struct ContextProgressBar: View {
    let percent: Double

    private var color: Color {
        switch percent {
        case 0..<50: return .blue
        case 50..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Context")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", percent))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.8))
                        .frame(width: max(geo.size.width * CGFloat(min(percent, 100) / 100), 0))
                }
            }
            .frame(height: 4)
        }
    }
}

// Collapsible card for history
struct CollapsibleCard<Content: View>: View {
    let title: String
    let icon: String
    let count: Int?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(.secondary)
                    Text(title)
                        .font(.subheadline.bold())
                    if let count = count {
                        Text("(\(count))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal)
                content()
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom)
            }
        }
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
    }
}

struct HistorySessionsCard: View {
    let sessions: [LiveSession]
    let allSessions: [LiveSession]  // All sessions for popup
    let formatTokens: (Int) -> String
    let formatCost: (Double) -> String
    @Binding var isExpanded: Bool

    var body: some View {
        CollapsibleCard(
            title: "Recent Projects",
            icon: "clock.arrow.circlepath",
            count: sessions.count,
            isExpanded: $isExpanded
        ) {
            if sessions.isEmpty {
                Text("No recent sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(session.projectName)
                                        .font(.caption)
                                        .lineLimit(1)
                                    // Show type badge for all projects
                                    Text(session.apiType.rawValue)
                                        .font(.system(size: 7, weight: .medium))
                                        .padding(.horizontal, 3)
                                        .foregroundColor(session.isAPI ? .orange : .blue)
                                        .cornerRadius(2)
                                }
                                Text(formatTokens(session.lastTokens) + " tokens")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            // Only show cost for API projects
                            if session.isAPI && session.lastCost > 0 {
                                Text(formatCost(session.lastCost))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    // Show All button
                    if allSessions.count > sessions.count {
                        PopoverAnchorButton(
                            title: "Show All",
                            count: allSessions.count
                        ) { anchorView in
                            PopoverManager.shared.showAllProjectsPopover(
                                anchorView: anchorView,
                                sessions: allSessions.sorted { $0.lastCost > $1.lastCost },
                                formatTokens: formatTokens,
                                formatCost: formatCost
                            )
                        }
                        .frame(height: 20)
                        .padding(.top, 4)
                    }
                }
            }
        }
    }
}
