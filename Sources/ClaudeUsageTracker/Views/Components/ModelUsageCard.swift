import SwiftUI

// All-time token usage broken down per Claude model, sourced from
// ~/.claude/stats-cache.json (modelUsage). This is the only surface that
// shows aggregate per-model usage — the live-sessions list only shows the
// model of an actively-running session.
struct ModelUsageCard: View {
    let models: [(name: String, displayName: String, tokens: Int, color: Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("USAGE BY MODEL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("ALL TIME")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundColor(.secondary.opacity(0.7))
            }

            ForEach(models, id: \.name) { model in
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.color)
                        .frame(width: 7, height: 7)

                    Text(model.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(formatTokens(model.tokens))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        switch count {
        case 0..<1000: return "\(count) tok"
        case 1000..<1_000_000: return String(format: "%.1fK tok", Double(count) / 1000)
        case 1_000_000..<1_000_000_000: return String(format: "%.1fM tok", Double(count) / 1_000_000)
        default: return String(format: "%.1fB tok", Double(count) / 1_000_000_000)
        }
    }
}
