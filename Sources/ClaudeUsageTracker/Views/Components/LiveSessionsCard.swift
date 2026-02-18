import SwiftUI

struct LiveSessionsCard: View {
    let sessions: [LiveClaudeSession]
    var isLoading: Bool = false
    var currentSession: SessionCache?
    var orphanedCount: Int = 0
    var orphanedMemoryMB: Int = 0
    var onKillSession: ((LiveClaudeSession) -> Void)?
    var onKillOrphaned: (() -> Void)?

    @State private var sessionToKill: LiveClaudeSession?
    @State private var killingSession: LiveClaudeSession?
    @State private var hoveredSession: String?
    @State private var confirmKillOrphaned: Bool = false

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
                        // Killing state
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
                        // Inline confirmation
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

                // Kill orphaned button
                if orphanedCount > 0 {
                    Divider()
                        .padding(.top, 4)

                    if confirmKillOrphaned {
                        HStack {
                            Text("Kill \(orphanedCount) orphaned sessions?")
                                .font(.caption)
                                .foregroundColor(.primary)
                            Spacer()
                            Button("Yes") {
                                onKillOrphaned?()
                                confirmKillOrphaned = false
                            }
                            .font(.caption.bold())
                            .foregroundColor(.red)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)

                            Button("No") {
                                confirmKillOrphaned = false
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    } else {
                        Button(action: { confirmKillOrphaned = true }) {
                            HStack {
                                Image(systemName: "trash")
                                    .font(.caption)
                                Text("Kill \(orphanedCount) orphaned")
                                    .font(.caption)
                                Spacer()
                                Text("\(orphanedMemoryMB) MB")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.orange)
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

// Collapsible card component
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
