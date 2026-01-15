import Foundation

struct SessionCache: Codable {
    let cwd: String?
    let model: SessionModel?
    let contextWindow: ContextWindow?
    let timestamp: Int64?

    enum CodingKeys: String, CodingKey {
        case cwd
        case model
        case contextWindow = "context_window"
        case timestamp
    }
}

struct SessionModel: Codable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct ContextWindow: Codable {
    let contextWindowSize: Int?
    let currentUsage: CurrentUsage?
    let usedPercentage: Double?
    let remainingPercentage: Double?
    let totalInputTokens: Int?
    let totalOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case contextWindowSize = "context_window_size"
        case currentUsage = "current_usage"
        case usedPercentage = "used_percentage"
        case remainingPercentage = "remaining_percentage"
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
    }

    var totalTokens: Int {
        return (totalInputTokens ?? 0) + (totalOutputTokens ?? 0)
    }

    // Estimate cost based on model and tokens (blended rate accounting for cache)
    func estimatedCost(modelId: String?) -> Double {
        let totalTok = Double(totalTokens)

        // Blended rate per million tokens (empirically calibrated with cache usage)
        let blendedRate: Double = {
            guard let model = modelId?.lowercased() else { return 10.0 }
            if model.contains("opus-4-5") || model.contains("opus-4.5") {
                return 24.0  // ~$24/MTok blended for Opus 4.5 with cache
            } else if model.contains("opus") {
                return 50.0  // Opus 3
            } else if model.contains("sonnet") {
                return 10.0  // Sonnet
            } else if model.contains("haiku") {
                return 1.0   // Haiku
            }
            return 10.0
        }()

        return totalTok * blendedRate / 1_000_000
    }
}

struct CurrentUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    var totalTokens: Int {
        return (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
    }
}
