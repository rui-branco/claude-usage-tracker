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

    var fiveHourUsedPercent: Double {
        Double(fiveHourUsed)
    }

    var sevenDayUsedPercent: Double {
        Double(sevenDayUsed)
    }

    var status: Status {
        let maxUsed = max(fiveHourUsedPercent, sevenDayUsedPercent)
        switch maxUsed {
        case 0..<50: return .healthy
        case 50..<80: return .warning
        default: return .critical
        }
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
