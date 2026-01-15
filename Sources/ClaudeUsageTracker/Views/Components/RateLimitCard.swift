import SwiftUI

struct RateLimitCard: View {
    let rateLimit: RateLimitStatus

    var body: some View {
        VStack(spacing: 10) {
            // Session Limit (5-Hour)
            RateLimitBar(
                label: "Session",
                percent: rateLimit.fiveHourUsedPercent,
                resetText: formatTimeUntil(rateLimit.fiveHourResetAt)
            )

            // Weekly Limit (7-Day)
            RateLimitBar(
                label: "Weekly",
                percent: rateLimit.sevenDayUsedPercent,
                resetText: formatResetDay(rateLimit.sevenDayResetAt)
            )
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
    }

    private func colorForPercent(_ percent: Double) -> Color {
        switch percent {
        case 0..<50: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resets soon" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    private func formatResetDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return "Resets \(formatter.string(from: date))"
    }
}

struct RateLimitBar: View {
    let label: String
    let percent: Double
    let resetText: String

    private var color: Color {
        switch percent {
        case 0..<50: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label row with reset time
            HStack {
                Text(label)
                    .font(.caption.bold())
                    .foregroundColor(.primary)
                Spacer()
                Text(resetText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Progress bar with percentage inside
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.15))

                    // Filled portion
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geo.size.width * CGFloat(min(percent, 100) / 100), 0))

                    // Percentage text
                    HStack {
                        Spacer()
                        Text("\(Int(percent))%")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                            .padding(.trailing, 8)
                    }
                }
            }
            .frame(height: 20)
        }
    }
}
