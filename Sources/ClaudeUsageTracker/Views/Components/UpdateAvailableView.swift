import SwiftUI

// MARK: - Update Available Banner

struct UpdateAvailableView: View {
    @ObservedObject var updateService: UpdateService
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var showingReleaseNotes = false

    var body: some View {
        if let release = updateService.latestRelease, updateService.updateAvailable {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundColor(.green)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update Available")
                                .font(.headline)

                            if let version = AppVersion(string: release.tagName) {
                                Text("Version \(version.description)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }

                    // Release notes preview
                    if !release.body.isEmpty {
                        Button {
                            showingReleaseNotes.toggle()
                        } label: {
                            HStack {
                                Text(showingReleaseNotes ? "Hide release notes" : "Show release notes")
                                    .font(.caption)
                                Image(systemName: showingReleaseNotes ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.link)

                        if showingReleaseNotes {
                            ScrollView {
                                Text(release.body)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                        }
                    }

                    // Download progress
                    if updateService.isDownloading {
                        VStack(spacing: 4) {
                            ProgressView(value: updateService.downloadProgress)
                                .progressViewStyle(.linear)

                            Text("Downloading... \(Int(updateService.downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Error message
                    if let error = downloadError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await downloadAndInstall()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if updateService.isDownloading {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: "arrow.down.to.line")
                                }
                                Text(updateService.isDownloading ? "Downloading..." : "Download Update")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(updateService.isDownloading)

                        Button("View on GitHub") {
                            updateService.openReleasePage()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Skip") {
                            updateService.skipVersion()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .font(.caption)
                    }

                    // Download size info
                    if let asset = release.zipAsset {
                        Text("Download size: \(asset.formattedSize)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(4)
            } label: {
                Label("Software Update", systemImage: "sparkles")
            }
        }
    }

    private func downloadAndInstall() async {
        downloadError = nil

        do {
            let zipURL = try await updateService.downloadUpdate()
            try await updateService.installUpdate(from: zipURL)
        } catch {
            downloadError = error.localizedDescription
        }
    }
}

// MARK: - Check for Updates Button

struct UpdateCheckButton: View {
    @ObservedObject var updateService: UpdateService
    @ObservedObject var settings: SettingsService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task {
                        // Clear skipped version when manually checking
                        updateService.clearSkippedVersion()
                        await updateService.checkForUpdates()
                        settings.lastUpdateCheck = Date()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if updateService.isChecking {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(updateService.isChecking ? "Checking..." : "Check for Updates")
                    }
                }
                .disabled(updateService.isChecking)

                Spacer()
            }

            // Status indicator below button
            if !updateService.isChecking, let result = updateService.checkResult {
                statusView(for: result)
            }
        }
    }

    @ViewBuilder
    private func statusView(for result: UpdateService.UpdateCheckResult) -> some View {
        switch result {
        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're up to date")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    if let lastCheck = SettingsService.shared.lastUpdateCheck {
                        Text("Checked \(formatTimeAgo(lastCheck))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

        case .updateAvailable(let version):
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.orange)
                    .font(.subheadline)
                Text("Version \(version.replacingOccurrences(of: "v", with: "")) available")
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 4)

        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.subheadline)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 4)
        }
    }

    private func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}

// MARK: - Last Check Time Formatter (kept for backwards compatibility)

struct LastUpdateCheckView: View {
    let date: Date?

    var body: some View {
        EmptyView()
    }
}
