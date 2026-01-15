import SwiftUI

struct TodayStatsCard: View {
    let messages: Int
    let sessions: Int
    let tokens: Int
    let formatTokens: (Int) -> String

    var body: some View {
        HStack(spacing: 0) {
            StatItem(title: "Messages", value: "\(messages)", icon: "message.fill")
            Divider().frame(height: 40)
            StatItem(title: "Sessions", value: "\(sessions)", icon: "terminal.fill")
            Divider().frame(height: 40)
            StatItem(title: "Tokens", value: formatTokens(tokens), icon: "textformat.123")
        }
        .padding(.vertical, 12)
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
