import Foundation
import PostHog

final class AnalyticsService {
    static let shared = AnalyticsService()

    // PostHog API key from environment or Secrets.swift (gitignored)
    private var apiKey: String {
        ProcessInfo.processInfo.environment["POSTHOG_API_KEY"] ?? Secrets.posthogAPIKey
    }

    private init() {}

    func initialize() {
        // PostHog requires bundle identifier - only works in .app bundle, not raw executable
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard !apiKey.isEmpty && apiKey != "YOUR-API-KEY-HERE" else { return }

        let config = PostHogConfig(
            apiKey: apiKey,
            host: "https://eu.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
    }

    // MARK: - App Lifecycle Events

    func trackAppLaunched() {
        PostHogSDK.shared.capture("app_launched", properties: [
            "version": Bundle.main.appVersion
        ])
        PostHogSDK.shared.flush()
    }

    func trackAppTerminated() {
        PostHogSDK.shared.capture("app_terminated")
    }

    // MARK: - Feature Usage Events

    func trackTimeFrameChanged(to timeFrame: String) {
        PostHogSDK.shared.capture("time_frame_changed", properties: [
            "time_frame": timeFrame
        ])
    }

    func trackSettingsOpened() {
        PostHogSDK.shared.capture("settings_opened")
    }

    func trackSettingChanged(setting: String, value: String) {
        PostHogSDK.shared.capture("setting_changed", properties: [
            "setting": setting,
            "value": value
        ])
    }

    func trackViewChanged(to view: String) {
        PostHogSDK.shared.capture("view_changed", properties: [
            "view": view
        ])
    }
}

// MARK: - Bundle Extension

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
