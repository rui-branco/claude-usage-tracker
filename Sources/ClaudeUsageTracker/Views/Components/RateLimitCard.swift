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

    private var shortResetText: String {
        // "Resets in 4h 26m" -> "4h 26m", "Resets Thu 22:59" -> "Thu 22:59"
        resetText
            .replacingOccurrences(of: "Resets in ", with: "")
            .replacingOccurrences(of: "Resets ", with: "")
    }

    private func shortEstimate(_ estimate: String) -> String {
        estimate
            .replacingOccurrences(of: "Limit in ", with: "")
            .replacingOccurrences(of: "!", with: "")
    }

    private var estimateColor: Color {
        guard let estimate = estimatedTimeToLimit else { return .secondary }
        if estimate.contains("At limit") { return .red }
        // "Limit in ~30m!" - minutes remaining, urgent
        if estimate.contains("m!") { return .orange }
        // "Limit in ~1.5h!" - hours remaining
        if estimate.contains("h!") {
            if let range = estimate.range(of: "~"),
               let endRange = estimate.range(of: "h"),
               let hours = Double(estimate[range.upperBound..<endRange.lowerBound]) {
                return hours < 2 ? .orange : .secondary
            }
        }
        // "Limit ~Mon!" - days remaining
        if estimate.contains("Limit ~") && !estimate.contains("in") {
            return .orange
        }
        return .secondary
    }
}

struct APICostBreakdown {
    var bedrockMonthly: Double = 0
    var bedrockTotal: Double = 0
    var claudeAPIMonthly: Double = 0
    var claudeAPITotal: Double = 0

    var totalMonthly: Double { bedrockMonthly + claudeAPIMonthly }
    var totalAll: Double { bedrockTotal + claudeAPITotal }
    var hasBedrock: Bool { bedrockTotal > 0 }
    var hasClaudeAPI: Bool { claudeAPITotal > 0 }
    var hasMultiple: Bool { hasBedrock && hasClaudeAPI }
}

struct APICostCard: View {
    let breakdown: APICostBreakdown
    var isLoading: Bool = false

    // Legacy init for backwards compatibility
    init(totalCost: Double, monthlyCost: Double, hasBedrock: Bool, hasClaudeAPI: Bool) {
        var b = APICostBreakdown()
        if hasBedrock {
            b.bedrockMonthly = monthlyCost
            b.bedrockTotal = totalCost
        } else {
            b.claudeAPIMonthly = monthlyCost
            b.claudeAPITotal = totalCost
        }
        self.breakdown = b
        self.isLoading = false
    }

    init(breakdown: APICostBreakdown, isLoading: Bool = false) {
        self.breakdown = breakdown
        self.isLoading = isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("API Cost")
                    .font(.caption.bold())
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }

            if isLoading && !breakdown.hasBedrock && !breakdown.hasClaudeAPI {
                Text("Calculating costs...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Show breakdown per API type
            if breakdown.hasBedrock {
                APITypeRow(
                    name: "Bedrock",
                    color: .orange,
                    monthly: breakdown.bedrockMonthly,
                    total: breakdown.bedrockTotal
                )
            }

            if breakdown.hasClaudeAPI {
                APITypeRow(
                    name: "Claude API",
                    color: .blue,
                    monthly: breakdown.claudeAPIMonthly,
                    total: breakdown.claudeAPITotal
                )
            }

            // Show combined total if multiple types
            if breakdown.hasMultiple {
                Divider()
                HStack {
                    Text("Total")
                        .font(.caption.bold())
                    Spacer()
                    Text(formatCost(breakdown.totalMonthly))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundColor(.orange)
                    Text("/")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formatCost(breakdown.totalAll))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "$0.00" }
        return String(format: "$%.2f", cost)
    }
}

struct APITypeRow: View {
    let name: String
    let color: Color
    let monthly: Double
    let total: Double

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatCost(monthly))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(color)
                Text("this month")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatCost(total))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Text("all time")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(width: 70)
        }
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "$0.00" }
        return String(format: "$%.2f", cost)
    }
}
