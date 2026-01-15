import SwiftUI

struct TrendChartView: View {
    let data: [DailyActivity]

    // Limit to last 14 days for readability, aggregate if more
    private var displayData: [DailyActivity] {
        let sorted = data.sorted { $0.date < $1.date }
        if sorted.count <= 14 {
            return sorted
        }
        // Show last 14 days
        return Array(sorted.suffix(14))
    }

    var body: some View {
        GeometryReader { geo in
            let chartData = displayData
            let maxMessages = chartData.map { $0.messageCount }.max() ?? 1
            let spacing: CGFloat = 3
            let barWidth = max(12, (geo.size.width - CGFloat(chartData.count - 1) * spacing) / CGFloat(max(chartData.count, 1)))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(chartData) { day in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor)
                            .frame(
                                width: barWidth,
                                height: max(4, (geo.size.height - 16) * CGFloat(day.messageCount) / CGFloat(maxMessages))
                            )
                        Text(formatDate(day.date))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .frame(width: barWidth)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func formatDate(_ dateStr: String) -> String {
        let components = dateStr.split(separator: "-")
        guard components.count >= 3 else { return dateStr }
        return String(components[2])
    }
}
