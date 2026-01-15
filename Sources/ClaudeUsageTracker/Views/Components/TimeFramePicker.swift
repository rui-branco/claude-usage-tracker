import SwiftUI

struct TimeFramePicker: View {
    @Binding var selection: TimeFrame

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TimeFrame.allCases) { frame in
                Button(action: {
                    selection = frame
                    AnalyticsService.shared.trackTimeFrameChanged(to: frame.rawValue)
                }) {
                    Text(frame.rawValue)
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selection == frame ? Color.accentColor : Color.gray.opacity(0.2))
                        .foregroundColor(selection == frame ? .white : .primary)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
