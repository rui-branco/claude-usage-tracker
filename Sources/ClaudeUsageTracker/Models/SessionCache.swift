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

    // Estimate cost based on model and tokens
    // Note: Most "input" tokens are actually cache reads (10x cheaper)
    // We use blended rates calibrated to match /cost output
    func estimatedCost(modelId: String?) -> Double {
        let inputTok = Double(totalInputTokens ?? 0)
        let outputTok = Double(totalOutputTokens ?? 0)

        // Blended rates per MTok (accounting for ~90% cache reads in typical usage)
        // Cache read is 10x cheaper than fresh input, so blended input rate is much lower
        let (inputBlendedRate, outputRate): (Double, Double) = {
            guard let model = modelId?.lowercased() else { return (0.57, 15.0) }
            if model.contains("opus-4-5") || model.contains("opus-4.5") || model.contains("opus_4_5") {
                // Opus 4.5: $5 input, $0.50 cache read, $25 output
                // Blended input: ~$0.95/MTok (90% cache at $0.50 + 10% fresh at $5)
                return (0.95, 25.0)
            } else if model.contains("opus") {
                // Opus 4/4.1: $15 input, $1.50 cache read, $75 output
                // Blended input: ~$2.85/MTok (90% cache at $1.50 + 10% fresh at $15)
                return (2.85, 75.0)
            } else if model.contains("haiku-4-5") || model.contains("haiku-4.5") || model.contains("haiku_4_5") {
                // Haiku 4.5: $1 input, $0.10 cache read, $5 output
                // Blended input: ~$0.19/MTok (90% cache at $0.10 + 10% fresh at $1)
                return (0.19, 5.0)
            } else if model.contains("haiku") {
                // Haiku 3.5: $0.80 input, $0.08 cache read, $4 output
                // Blended input: ~$0.152/MTok (90% cache at $0.08 + 10% fresh at $0.80)
                return (0.152, 4.0)
            } else if model.contains("sonnet") {
                // Sonnet: $3 input, $0.30 cache read, $15 output
                // Blended input: ~$0.57/MTok (90% cache at $0.30 + 10% fresh at $3)
                return (0.57, 15.0)
            }
            return (0.57, 15.0)
        }()

        let inputCost = inputTok * inputBlendedRate / 1_000_000
        let outputCost = outputTok * outputRate / 1_000_000
        return inputCost + outputCost
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
