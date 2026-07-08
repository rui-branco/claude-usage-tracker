import SwiftUI
import AppKit

struct RateLimitCard: View {
    let rateLimit: RateLimitStatus?
    var codexLimits: CodexRateLimitStatus? = nil
    var geminiLimits: GeminiRateLimitStatus? = nil
    @State private var refreshTrigger = Date()

    private var hasMultipleProviders: Bool {
        let count = (rateLimit != nil ? 1 : 0)
                  + (codexLimits != nil ? 1 : 0)
                  + (geminiLimits != nil ? 1 : 0)
        return count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if rateLimit == nil && (codexLimits != nil || geminiLimits != nil) {
                // Other providers have data but Claude API is unreachable — make it explicit.
                VStack(alignment: .leading, spacing: 4) {
                    SourceLabel(text: "CLAUDE", color: .orange, iconAsset: "claude-icon")
                    Text("Anthropic usage API unavailable (rate-limited). Will retry.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Divider().opacity(0.4)
            }

            if let rateLimit = rateLimit {
                if hasMultipleProviders {
                    SourceLabel(text: "CLAUDE", color: .orange, iconAsset: "claude-icon")
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

                // Per-model weekly caps (e.g. Fable), from the usage API's limits list.
                ForEach(Array(rateLimit.scopedWeekly.enumerated()), id: \.offset) { _, scoped in
                    RateLimitBar(
                        label: scoped.name,
                        percent: Double(scoped.used),
                        resetText: formatResetDay(scoped.resetAt),
                        tickCount: 7
                    )
                }
            }

            if let codex = codexLimits {
                if rateLimit != nil {
                    Divider().opacity(0.4)
                }
                SourceLabel(text: "CODEX\(codex.planType.isEmpty ? "" : " · \(codex.planType.uppercased())")", color: .green, iconAsset: "codex-icon")

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

            if let gemini = geminiLimits {
                if rateLimit != nil || codexLimits != nil {
                    Divider().opacity(0.4)
                }
                SourceLabel(text: "ANTIGRAVITY", color: .blue, iconAsset: "gemini-icon")

                // One bar per model returned by the quota API. The worst one drives
                // MenuBarState.geminiSessionPercent (see GeminiService.probeQuota).
                ForEach(Array(gemini.perModel.enumerated()), id: \.offset) { _, entry in
                    RateLimitBar(
                        label: shortGeminiModelName(entry.model),
                        percent: entry.usedPercent,
                        resetText: entry.resetAt.map { formatGeminiResetClock($0) } ?? "—",
                        tickCount: 0
                    )
                }
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

    /// Gemini's quota always resets in ~24h, so a "RESETS 23H 22M" countdown is just
    /// visual noise. Show the actual clock time the reset will happen, with a TMR/TODAY
    /// hint when the reset crosses local midnight.
    private func formatGeminiResetClock(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let time = timeFmt.string(from: date)
        if calendar.isDateInToday(date) { return "TODAY \(time)" }
        if calendar.isDateInTomorrow(date) { return "TMR \(time)" }
        if date < now.addingTimeInterval(7 * 86400) {
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "EEE"
            return "\(dayFmt.string(from: date)) \(time)"
        }
        let fallback = DateFormatter()
        fallback.dateFormat = "MMM d HH:mm"
        return fallback.string(from: date)
    }

    /// Strip the redundant "gemini-" prefix; otherwise show the raw modelId so users
    /// can tell which bucket each bar represents (e.g. preview vs stable variants).
    private func shortGeminiModelName(_ id: String) -> String {
        var trimmed = id
        if trimmed.lowercased().hasPrefix("gemini-") {
            trimmed = String(trimmed.dropFirst("gemini-".count))
        } else if trimmed.lowercased().hasPrefix("gemini ") {
            trimmed = String(trimmed.dropFirst("gemini ".count))
        }
        return trimmed
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

// Small uppercase tag identifying the source (Claude / Codex / Gemini) inside a shared card.
struct SourceLabel: View {
    let text: String
    let color: Color
    var iconAsset: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let asset = iconAsset {
                ProviderBrandIcon(asset: asset, size: 12)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.4)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

/// Brand logo loaded from `Resources/<asset>.png`. Falls back to a circle
/// if the asset is missing so the layout never breaks.
struct ProviderBrandIcon: View {
    let asset: String
    var size: CGFloat = 12

    var body: some View {
        if let url = ResourceLoader.url(forResource: asset, withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            nsImage.size = NSSize(width: size, height: size)
            return AnyView(
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            )
        } else {
            return AnyView(
                Circle()
                    .fill(Color.secondary)
                    .frame(width: size * 0.5, height: size * 0.5)
            )
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 44, alignment: .leading)

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
