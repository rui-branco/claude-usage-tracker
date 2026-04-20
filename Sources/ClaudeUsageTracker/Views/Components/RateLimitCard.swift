import SwiftUI

struct RateLimitCard: View {
    let rateLimit: RateLimitStatus
    @State private var refreshTrigger = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RateLimitBar(
                label: "Session",
                percent: rateLimit.fiveHourUsedPercent,
                resetText: formatTimeUntil(rateLimit.fiveHourResetAt),
                estimatedTimeToLimit: rateLimit.sessionTimeUntilLimitFormatted,
                burnRateText: rateLimit.sessionBurnRateFormatted,
                etaToFullText: rateLimit.sessionETAFormatted,
                etaIsWarning: rateLimit.sessionEndsBeforeReset,
                tickCount: 5
            )

            RateLimitBar(
                label: "Weekly",
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
        if interval <= 0 { return "soon" }

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
    let percent: Double
    let resetText: String
    var estimatedTimeToLimit: String?
    var burnRateText: String?
    var etaToFullText: String?
    var etaIsWarning: Bool = false
    var tickCount: Int = 0

    private var color: Color {
        switch percent {
        case 0..<50: return Color(red: 0.47, green: 0.75, blue: 0.51)   // muted sage green
        case 50..<80: return Color(red: 0.92, green: 0.76, blue: 0.40)  // warm amber yellow
        default: return Color(red: 0.88, green: 0.48, blue: 0.44)       // dusty coral red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            barRow
            statusRow
        }
    }

    private var headerRow: some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)

            Spacer()

            Text("RESETS \(resetText.uppercased())")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .tracking(0.8)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    private var barRow: some View {
        HStack(spacing: 10) {
            Text("\(Int(percent))%")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundColor(color)
                .frame(width: 38, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))

                    Rectangle()
                        .fill(color)
                        .frame(width: max(geo.size.width * CGFloat(min(percent, 100) / 100), 0))

                    if tickCount > 1 {
                        ForEach(1..<tickCount, id: \.self) { i in
                            Rectangle()
                                .fill(Color.black.opacity(0.3))
                                .frame(width: 1)
                                .position(x: geo.size.width * CGFloat(i) / CGFloat(tickCount), y: 2)
                        }
                    }
                }
            }
            .frame(height: 4)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if burnRateText != nil || etaToFullText != nil {
            HStack(spacing: 8) {
                if let rate = burnRateText {
                    Text(rate)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                if burnRateText != nil && etaToFullText != nil {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                }

                if let eta = etaToFullText {
                    Text(eta)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(etaIsWarning ? .red : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                Spacer(minLength: 0)
            }
        }
    }
}
