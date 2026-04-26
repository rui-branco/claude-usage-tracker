import SwiftUI

struct RateLimitCard: View {
    let rateLimit: RateLimitStatus?
    var codexLimits: CodexRateLimitStatus? = nil
    @State private var refreshTrigger = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if rateLimit == nil && codexLimits != nil {
                // Codex has data but Claude API is unreachable — make it explicit.
                VStack(alignment: .leading, spacing: 4) {
                    SourceLabel(text: "CLAUDE", color: .orange)
                    Text("Anthropic usage API unavailable (rate-limited). Will retry.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Divider().opacity(0.4)
            }

            if let rateLimit = rateLimit {
                if codexLimits != nil {
                    SourceLabel(text: "CLAUDE", color: .orange)
                }

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

            if let codex = codexLimits {
                if rateLimit != nil {
                    Divider().opacity(0.4)
                }
                SourceLabel(text: "CODEX\(codex.planType.isEmpty ? "" : " · \(codex.planType.uppercased())")", color: .green)

                // When the saved reset has elapsed the window has rolled over —
                // show the bar at 0% rather than carrying the stale percentage.
                RateLimitBar(
                    label: "Session",
                    percent: codex.primaryIsStale ? 0 : codex.primaryUsedPercent,
                    resetText: codex.primaryIsStale ? "—" : formatTimeUntil(codex.primaryResetAt),
                    tickCount: 5
                )

                RateLimitBar(
                    label: "Weekly",
                    percent: codex.secondaryIsStale ? 0 : codex.secondaryUsedPercent,
                    resetText: codex.secondaryIsStale ? "—" : formatResetDay(codex.secondaryResetAt),
                    tickCount: 7
                )
            }
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

// Shown when codex's saved reset time has elapsed — the percent we cached is from
// a previous window and there's no fresh observation to replace it yet.
struct StaleBarPlaceholder: View {
    let label: String
    let lastSeen: Date

    var body: some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)
            Spacer()
            Text("NO RECENT DATA · \(timeAgo(lastSeen))")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 3600 { return "\(Int(interval / 60))M AGO" }
        if interval < 86400 { return "\(Int(interval / 3600))H AGO" }
        return "\(Int(interval / 86400))D AGO"
    }
}

// Small uppercase tag identifying the source (Claude / Codex) inside a shared card.
struct SourceLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.4)
                .foregroundColor(.secondary)
            Spacer()
        }
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
