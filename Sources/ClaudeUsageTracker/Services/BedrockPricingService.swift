import Foundation

struct BedrockPricing: Codable {
    var lastUpdated: Date
    var models: [String: ModelPricing]
}

struct ModelPricing: Codable {
    let inputPerMTok: Double   // Price per million input tokens
    let outputPerMTok: Double  // Price per million output tokens
}

@MainActor
class BedrockPricingService: ObservableObject {
    static let shared = BedrockPricingService()

    @Published var pricing: BedrockPricing?

    private let pricingFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClaudeUsageTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("bedrock-pricing.json")
    }()

    // Default pricing from Anthropic (Jan 2025)
    private let defaultPricing: [String: ModelPricing] = [
        // Claude 3 Haiku
        "haiku-3": ModelPricing(inputPerMTok: 0.25, outputPerMTok: 1.25),
        "claude-3-haiku": ModelPricing(inputPerMTok: 0.25, outputPerMTok: 1.25),

        // Claude 3.5/4.5 Haiku
        "haiku-4": ModelPricing(inputPerMTok: 1.0, outputPerMTok: 5.0),
        "haiku-4.5": ModelPricing(inputPerMTok: 1.0, outputPerMTok: 5.0),

        // Claude Sonnet
        "sonnet-3.5": ModelPricing(inputPerMTok: 3.0, outputPerMTok: 15.0),
        "sonnet-4": ModelPricing(inputPerMTok: 3.0, outputPerMTok: 15.0),
        "sonnet-4.5": ModelPricing(inputPerMTok: 3.0, outputPerMTok: 15.0),

        // Claude Opus
        "opus-4": ModelPricing(inputPerMTok: 15.0, outputPerMTok: 75.0),
        "opus-4.1": ModelPricing(inputPerMTok: 15.0, outputPerMTok: 75.0),
        "opus-4.5": ModelPricing(inputPerMTok: 5.0, outputPerMTok: 25.0),
    ]

    init() {
        loadPricing()
    }

    func loadPricing() {
        if FileManager.default.fileExists(atPath: pricingFileURL.path) {
            do {
                let data = try Data(contentsOf: pricingFileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                pricing = try decoder.decode(BedrockPricing.self, from: data)
            } catch {
                createDefaultPricing()
            }
        } else {
            createDefaultPricing()
        }
    }

    private func createDefaultPricing() {
        pricing = BedrockPricing(lastUpdated: Date(), models: defaultPricing)
        savePricing()
    }

    func savePricing() {
        guard let pricing = pricing else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(pricing)
            try data.write(to: pricingFileURL)
        } catch {
            print("Failed to save pricing: \(error)")
        }
    }

    func getPricing(for model: String) -> (input: Double, output: Double) {
        let modelLower = model.lowercased()

        // Determine model family
        if modelLower.contains("haiku") {
            if modelLower.contains("claude-3-haiku") || modelLower.contains("20240307") {
                return getPricingForKey("haiku-3")
            }
            return getPricingForKey("haiku-4.5")
        } else if modelLower.contains("sonnet") {
            return getPricingForKey("sonnet-4.5")
        } else if modelLower.contains("opus") {
            if modelLower.contains("4.5") || modelLower.contains("20251101") {
                return getPricingForKey("opus-4.5")
            }
            return getPricingForKey("opus-4")
        }

        // Default to Sonnet pricing
        return getPricingForKey("sonnet-4")
    }

    private func getPricingForKey(_ key: String) -> (input: Double, output: Double) {
        if let modelPricing = pricing?.models[key] {
            return (modelPricing.inputPerMTok, modelPricing.outputPerMTok)
        }
        if let defaultModel = defaultPricing[key] {
            return (defaultModel.inputPerMTok, defaultModel.outputPerMTok)
        }
        return (3.0, 15.0) // Ultimate fallback
    }

    func calculateCost(inputTokens: Int, outputTokens: Int, model: String) -> Double {
        let (inputPrice, outputPrice) = getPricing(for: model)
        let inputCost = Double(inputTokens) * inputPrice / 1_000_000
        let outputCost = Double(outputTokens) * outputPrice / 1_000_000
        return inputCost + outputCost
    }
}
