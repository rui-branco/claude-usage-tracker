import SwiftUI

struct RateLimitCard: View {
    let rateLimit: RateLimitStatus
    @State private var refreshTrigger = Date()

    var body: some View {
        VStack(spacing: 10) {
            // Session Limit (5-Hour)
            RateLimitBar(
                label: "Session",
                icon: "clock.fill",
                percent: rateLimit.fiveHourUsedPercent,
                resetText: formatTimeUntil(rateLimit.fiveHourResetAt),
                estimatedTimeToLimit: rateLimit.sessionTimeUntilLimitFormatted,
                burnRateText: rateLimit.sessionBurnRateFormatted,
                etaToFullText: rateLimit.sessionETAFormatted,
                etaIsWarning: rateLimit.sessionEndsBeforeReset,
                tickCount: 5
            )

            // Weekly Limit (7-Day)
            RateLimitBar(
                label: "Weekly",
                icon: "calendar",
                percent: rateLimit.sevenDayUsedPercent,
                resetText: formatResetDay(rateLimit.sevenDayResetAt),
                estimatedTimeToLimit: rateLimit.weeklyTimeUntilLimitFormatted,
                burnRateText: rateLimit.weeklyBurnRateFormatted,
                etaToFullText: rateLimit.weeklyETAFormatted,
                etaIsWarning: rateLimit.weeklyEndsBeforeReset,
                tickCount: 7
            )
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { time in
            refreshTrigger = time
        }
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "Resets soon" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatResetDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }
}

struct RateLimitBar: View {
    let label: String
    var icon: String = "gauge.medium"
    let percent: Double
    let resetText: String
    var estimatedTimeToLimit: String?
    var burnRateText: String?
    var etaToFullText: String?
    var etaIsWarning: Bool = false
    var tickCount: Int = 0

    private var color: Color {
        switch percent {
        case 0..<50: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.75), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            percentAndRateRow
            progressBar
            footerPills
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 14)

            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8, weight: .medium))
                Text(resetText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
            .foregroundColor(.secondary)
        }
    }

    private var percentAndRateRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(percent))")
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(color)
                Text("%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(color.opacity(0.7))
            }

            Spacer()

            if let rate = burnRateText {
                pill(
                    icon: "chart.line.uptrend.xyaxis",
                    text: rate,
                    color: color
                )
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))

                Capsule()
                    .fill(barGradient)
                    .frame(width: max(geo.size.width * CGFloat(min(percent, 100) / 100), 0))

                if tickCount > 1 {
                    ForEach(1..<tickCount, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 1)
                            .position(x: geo.size.width * CGFloat(i) / CGFloat(tickCount), y: 4)
                    }
                }
            }
        }
        .frame(height: 8)
    }

    @ViewBuilder
    private var footerPills: some View {
        if etaToFullText != nil || estimatedTimeToLimit != nil {
            HStack(spacing: 6) {
                if let eta = etaToFullText {
                    pill(
                        icon: etaIsWarning ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                        text: eta,
                        color: etaIsWarning ? .red : .green
                    )
                }

                if let estimate = estimatedTimeToLimit {
                    pill(
                        icon: "flame.fill",
                        text: estimate,
                        color: .orange
                    )
                }

                Spacer()
            }
        }
    }

    private func pill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(0.14))
        )
    }
}
