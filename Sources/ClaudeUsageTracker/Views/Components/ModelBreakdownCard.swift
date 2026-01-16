import SwiftUI

struct ModelBreakdownCard: View {
    let models: [(name: String, displayName: String, tokens: Int, color: Color, apiCost: Double)]
    let formatTokens: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models")
                    .font(.subheadline.bold())
                Spacer()
                Text("API")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            ForEach(models, id: \.name) { model in
                HStack {
                    Circle()
                        .fill(model.color)
                        .frame(width: 10, height: 10)
                    Text(model.displayName)
                        .font(.caption)
                    Spacer()
                    Text(formatTokens(model.tokens))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text(formatAPICost(model.apiCost))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
    }

    private func formatAPICost(_ cost: Double) -> String {
        if cost < 0.01 { return "<$0.01" }
        if cost < 1 { return String(format: "$%.2f", cost) }
        return String(format: "$%.0f", cost)
    }
}
