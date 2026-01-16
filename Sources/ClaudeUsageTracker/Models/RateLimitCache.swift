import Foundation

struct RateLimitCache: Codable {
    let data: RateLimitData
    let timestamp: Int
}

struct RateLimitData: Codable {
    let planName: String
    let fiveHour: Int
    let sevenDay: Int
    let fiveHourResetAt: String
    let sevenDayResetAt: String
}

struct RateLimitStatus {
    let planName: String
    let fiveHourUsed: Int      // Percentage used (0-100)
    let sevenDayUsed: Int      // Percentage used (0-100)
    let fiveHourResetAt: Date
    let sevenDayResetAt: Date

    // Recent burn rate tracking (calculated from delta since last check)
    var recentSessionBurnRate: Double?   // % per hour based on recent change
    var recentWeeklyBurnRate: Double?    // % per hour based on recent change

    var fiveHourUsedPercent: Double {
        Double(fiveHourUsed)
    }

    var sevenDayUsedPercent: Double {
        Double(sevenDayUsed)
    }

    /// Projected session usage at reset time using effective burn rate
    var sessionProjectedPercent: Double? {
        let windowDuration: TimeInterval = 5 * 3600
        let timeUntilReset = fiveHourResetAt.timeIntervalSinceNow
        let elapsedInWindow = windowDuration - max(timeUntilReset, 0)

        guard fiveHourUsedPercent > 0 else { return nil }

        // Use same effective rate as the time-to-limit calculation
        // Require at least 15 minutes elapsed for meaningful average
        var avgBurnRate: Double = 0
        if elapsedInWindow > 900 {
            avgBurnRate = fiveHourUsedPercent / (elapsedInWindow / 3600.0)
        }
        let effectiveRate = max(avgBurnRate, recentSessionBurnRate ?? 0)
        guard effectiveRate > 0 else { return nil }

        let hoursUntilReset = timeUntilReset / 3600.0
        let projectedAdditional = effectiveRate * max(hoursUntilReset, 0)
        return min(fiveHourUsedPercent + projectedAdditional, 100)
    }

    /// Projected weekly usage at reset time using effective burn rate
    var weeklyProjectedPercent: Double? {
        let windowDuration: TimeInterval = 7 * 24 * 3600
        let timeUntilReset = sevenDayResetAt.timeIntervalSinceNow
        let elapsedInWindow = windowDuration - max(timeUntilReset, 0)

        guard sevenDayUsedPercent > 0 else { return nil }

        // Use same effective rate as the time-to-limit calculation
        // Require at least 4 hours elapsed for meaningful weekly average
        var avgBurnRate: Double = 0
        if elapsedInWindow > 14400 {
            avgBurnRate = sevenDayUsedPercent / (elapsedInWindow / 3600.0)
        }
        let effectiveRate = max(avgBurnRate, recentWeeklyBurnRate ?? 0)
        guard effectiveRate > 0 else { return nil }

        let hoursUntilReset = timeUntilReset / 3600.0
        let projectedAdditional = effectiveRate * max(hoursUntilReset, 0)
        return min(sevenDayUsedPercent + projectedAdditional, 100)
    }

    /// Time-based marker position for weekly (0-100% of 7-day window)
    /// Shows WHEN the limit will be hit as a position on the timeline
    var weeklyLimitTimePosition: Double? {
        guard let hours = weeklyHoursUntilLimit else { return nil }

        let windowDuration: TimeInterval = 7 * 24 * 3600  // 7 days
        let timeUntilReset = sevenDayResetAt.timeIntervalSinceNow
        let elapsedInWindow = windowDuration - max(timeUntilReset, 0)

        // Position = elapsed time + time to limit, as % of 7 days
        let timeToLimitSeconds = hours * 3600
        let limitPosition = (elapsedInWindow + timeToLimitSeconds) / windowDuration * 100

        return min(limitPosition, 100)
    }

    /// Time-based marker position for session (0-100% of 5-hour window)
    var sessionLimitTimePosition: Double? {
        guard let minutes = sessionMinutesUntilLimit else { return nil }

        let windowDuration: TimeInterval = 5 * 3600  // 5 hours
        let timeUntilReset = fiveHourResetAt.timeIntervalSinceNow
        let elapsedInWindow = windowDuration - max(timeUntilReset, 0)

        // Position = elapsed time + time to limit, as % of 5 hours
        let timeToLimitSeconds = minutes * 60
        let limitPosition = (elapsedInWindow + timeToLimitSeconds) / windowDuration * 100

        return min(limitPosition, 100)
    }

    var status: Status {
        let maxUsed = max(fiveHourUsedPercent, sevenDayUsedPercent)
        switch maxUsed {
        case 0..<50: return .healthy
        case 50..<80: return .warning
        default: return .critical
        }
    }

    /// Estimated time until session limit is reached (in minutes)
    /// Uses MAX of average rate and recent rate for faster spike detection
    var sessionMinutesUntilLimit: Double? {
        let windowDuration: TimeInterval = 5 * 3600  // 5 hours
        let timeUntilReset = fiveHourResetAt.timeIntervalSinceNow
        let elapsedInWindow = windowDuration - max(timeUntilReset, 0)

        guard fiveHourUsedPercent > 0 else { return nil }

        // Calculate average rate over entire window
        // Require at least 15 minutes elapsed for meaningful average (avoid early spike false alarms)
        var avgBurnRate: Double = 0
        if elapsedInWindow > 900 {
            let elapsedHours = elapsedInWindow / 3600.0
            avgBurnRate = fiveHourUsedPercent / elapsedHours
        }

        // Use MAX of average rate and recent rate (catches spikes faster)
        let effectiveRate = max(avgBurnRate, recentSessionBurnRate ?? 0)

        guard effectiveRate > 0 else { return nil }

        let remaining = 100.0 - fiveHourUsedPercent
        guard remaining > 0 else { return 0 }

        return (remaining / effectiveRate) * 60  // Convert hours to minutes
    }

    /// Estimated time until weekly limit is reached (in hours)
    /// Uses MAX of average rate and recent rate for faster spike detection
    var weeklyHoursUntilLimit: Double? {
        let windowDuration: TimeInterval = 7 * 24 * 3600  // 7 days
        let timeUntilReset = sevenDayResetAt.timeIntervalSinceNow
        let elapsedInWindow = windowDuration - max(timeUntilReset, 0)

        guard sevenDayUsedPercent > 0 else { return nil }

        // Calculate average rate over entire window
        // Require at least 4 hours elapsed for meaningful weekly average (avoid early spike false alarms)
        var avgBurnRate: Double = 0
        if elapsedInWindow > 14400 {
            let elapsedHours = elapsedInWindow / 3600.0
            avgBurnRate = sevenDayUsedPercent / elapsedHours
        }

        // Use MAX of average rate and recent rate (catches spikes faster)
        let effectiveRate = max(avgBurnRate, recentWeeklyBurnRate ?? 0)

        guard effectiveRate > 0 else { return nil }

        let remaining = 100.0 - sevenDayUsedPercent
        guard remaining > 0 else { return 0 }

        return remaining / effectiveRate
    }

    /// Formatted string for session time until limit
    /// Only shows if burning WAY too fast (hitting limit well before reset)
    var sessionTimeUntilLimitFormatted: String? {
        guard let minutes = sessionMinutesUntilLimit else { return nil }

        if minutes <= 0 { return "At limit!" }

        // Calculate the actual limit date
        let limitDate = Date().addingTimeInterval(minutes * 60)

        // Only show if hitting limit BEFORE reset (with 5 min buffer)
        let bufferDate = fiveHourResetAt.addingTimeInterval(-5 * 60)
        guard limitDate < bufferDate else { return nil }

        // Show day name + time format (consistent with weekly)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"  // e.g., "Fri 22:00"
        return "Limit ~\(formatter.string(from: limitDate))"
    }

    /// Formatted string for weekly time until limit
    /// Only shows if burning WAY too fast (hitting limit well before reset)
    var weeklyTimeUntilLimitFormatted: String? {
        guard let hours = weeklyHoursUntilLimit else { return nil }

        if hours <= 0 { return "At limit!" }

        // Calculate the actual limit date
        let limitDate = Date().addingTimeInterval(hours * 3600)

        // Only show if hitting limit BEFORE reset (with 30 min buffer)
        let bufferDate = sevenDayResetAt.addingTimeInterval(-30 * 60)
        guard limitDate < bufferDate else { return nil }

        // Show day name + time for weekly
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"  // e.g., "Wed 15:30"
        return "Limit ~\(formatter.string(from: limitDate))"
    }

    enum Status {
        case healthy, warning, critical

        var color: String {
            switch self {
            case .healthy: return "green"
            case .warning: return "orange"
            case .critical: return "red"
            }
        }
    }
}
