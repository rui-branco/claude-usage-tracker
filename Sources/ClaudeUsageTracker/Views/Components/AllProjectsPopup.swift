import SwiftUI

struct AllProjectsPopup: View {
    let sessions: [LiveSession]
    let formatTokens: (Int) -> String
    let formatCost: (Double) -> String
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("All Projects")
                    .font(.headline)
                Spacer()
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Projects list
            if sessions.isEmpty {
                Text("No projects found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(sessions) { session in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(session.projectName)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                        // Show type badge for all projects
                                        Text(session.apiType.rawValue)
                                            .font(.system(size: 8, weight: .medium))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(session.isAPI ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                                            .foregroundColor(session.isAPI ? .orange : .blue)
                                            .cornerRadius(3)
                                    }
                                    Text(session.projectPath)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatTokens(session.lastTokens))
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    // Only show cost for API projects
                                    if session.isAPI && session.lastCost > 0 {
                                        Text(formatCost(session.lastCost))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .background(Color(.windowBackgroundColor))
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}
