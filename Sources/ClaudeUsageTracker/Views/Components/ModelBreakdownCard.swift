import SwiftUI

struct ModelBreakdownCard: View {
    let models: [(name: String, displayName: String, tokens: Int, color: Color)]
    let formatTokens: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models")
                .font(.subheadline.bold())

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
                }
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor))
        .cornerRadius(10)
    }
}
