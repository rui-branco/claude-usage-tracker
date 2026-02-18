import SwiftUI

struct RateLimitCard: View {
    let rateLimit: RateLimitStatus
    @State private var refreshTrigger = Date()

    var body: some View {
        VStack(spacing: 8) {
            // Session Limit (5-Hour)
            RateLimitBar(
                label: "Session",
                percent: rateLimit.fiveHourUsedPercent,
                resetText: formatTimeUntil(rateLimit.fiveHourResetAt),
                estimatedTimeToLimit: rateLimit.sessionTimeUntilLimitFormatted,
                tickCount: 5
            )

            // Weekly Limit (7-Day)
            RateLimitBar(
                label: "Weekly",
                percent: rateLimit.sevenDayUsedPercent,
                resetText: formatResetDay(rateLimit.sevenDayResetAt),
                estimatedTimeToLimit: rateLimit.weeklyTimeUntilLimitFormatted,
                tickCount: 7
            )
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { time in
            refreshTrigger = time
        }
        .padding(12)
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
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
    var estimatedTimeToLimit: String?
    var tickCount: Int = 0

    private var color: Color {
        switch percent {
        case 0..<50: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            // Progress bar with percentage
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.15))

                        RoundedRectangle(cornerRadius: 3)
                            .fill(color)
                            .frame(width: max(geo.size.width * CGFloat(min(percent, 100) / 100), 0))

                        // Tick marks overlay
                        if tickCount > 1 {
                            ForEach(1..<tickCount, id: \.self) { i in
                                Rectangle()
                                    .fill(Color.white.opacity(0.5))
                                    .frame(width: 1, height: 8)
                                    .position(x: geo.size.width * CGFloat(i) / CGFloat(tickCount), y: 4)
                            }
                        }

                    }
                }
                .frame(height: 8)

                Text("\(Int(percent))%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(color)
                    .frame(width: 32, alignment: .trailing)
            }

            // Estimated time to limit (shown below bar)
            if let estimate = estimatedTimeToLimit {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 8))
                    Text(estimate)
                        .font(.system(size: 9))
                }
                .foregroundColor(.gray)
            }
        }
    }
}
