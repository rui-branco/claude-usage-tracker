import Foundation

struct ModelPricing: Codable {
    let inputPerMTok: Double      // Price per million input tokens
    let outputPerMTok: Double     // Price per million output tokens
    let cacheWritePerMTok: Double // Price per million cache write tokens
    let cacheReadPerMTok: Double  // Price per million cache read tokens

    init(inputPerMTok: Double, outputPerMTok: Double, cacheWritePerMTok: Double, cacheReadPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
    }
}

/// A pricing period with date range
struct PricingPeriod: Codable {
    let from: String        // ISO date "2024-01-01"
    let to: String?         // ISO date or null for current
    let models: [String: ModelPricing]
}

/// Pricing config with history for accurate calculations across time
struct PricingConfig: Codable {
    var lastUpdated: String
    var source: String
    var history: [PricingPeriod]

    // Legacy support - single models dict
    var models: [String: ModelPricing]?

    /// Get the current (most recent) pricing period
    var currentPricing: [String: ModelPricing] {
        // Find period with no end date (current)
        if let current = history.first(where: { $0.to == nil }) {
            return current.models
        }
        // Fallback to most recent by start date
        if let latest = history.sorted(by: { $0.from > $1.from }).first {
            return latest.models
        }
        // Legacy fallback
        return models ?? [:]
    }
}

/// Pricing service that reads from bundled pricing.json resource
/// Update Resources/pricing.json to change prices
final class PricingService: @unchecked Sendable {
    static let shared = PricingService()

    private var config: PricingConfig?

    /// Fallback default config if bundled resource fails to load
    private var defaultConfig: PricingConfig {
        PricingConfig(
            lastUpdated: "2026-01-16",
            source: "Built-in fallback",
            history: [
                PricingPeriod(from: "2025-11-24", to: nil, models: [
                    "opus-4-5": ModelPricing(inputPerMTok: 5, outputPerMTok: 25, cacheWritePerMTok: 6.25, cacheReadPerMTok: 0.5),
                    "opus": ModelPricing(inputPerMTok: 15, outputPerMTok: 75, cacheWritePerMTok: 18.75, cacheReadPerMTok: 1.5),
                    "sonnet": ModelPricing(inputPerMTok: 3, outputPerMTok: 15, cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.3),
                    "haiku-4-5": ModelPricing(inputPerMTok: 1, outputPerMTok: 5, cacheWritePerMTok: 1.25, cacheReadPerMTok: 0.1),
                    "haiku": ModelPricing(inputPerMTok: 0.8, outputPerMTok: 4, cacheWritePerMTok: 1, cacheReadPerMTok: 0.08)
                ])
            ],
            models: nil
        )
    }

    init() {
        loadPricing()
    }

    func loadPricing() {
        // Load from bundled resource file
        guard let url = ResourceLoader.url(forResource: "pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let loadedConfig = try? JSONDecoder().decode(PricingConfig.self, from: data) else {
            // Fallback to minimal defaults if resource not found
            config = defaultConfig
            return
        }
        config = loadedConfig
    }

    /// Get pricing for a model (with version support) at a specific date
    /// If no date provided, uses current pricing
    /// Checks for specific model versions (e.g., opus-4-5) before falling back to family (e.g., opus)
    func getPricing(for model: String, at date: Date? = nil) -> ModelPricing {
        let modelLower = model.lowercased()
        let currentConfig = config ?? defaultConfig

        // Get pricing for the date
        let models = getPricingModels(for: date, from: currentConfig)

        // Check for specific model versions first, then fall back to family
        // Note: "claude-haiku" without version means the current default (haiku-4-5 since Oct 2025)
        // Similarly "claude-opus" without version would mean the current default
        let modelKey: String
        let fallbackKey: String

        if modelLower.contains("opus-4-5") || modelLower.contains("opus-4.5") || modelLower.contains("opus_4_5") {
            modelKey = "opus-4-5"
            fallbackKey = "opus"
        } else if modelLower.contains("opus") {
            // Unversioned opus - check if opus-4-5 is available (current default)
            modelKey = models["opus-4-5"] != nil ? "opus-4-5" : "opus"
            fallbackKey = "opus"
        } else if modelLower.contains("haiku-4-5") || modelLower.contains("haiku-4.5") || modelLower.contains("haiku_4_5") {
            modelKey = "haiku-4-5"
            fallbackKey = "haiku"
        } else if modelLower.contains("haiku") {
            // Unversioned haiku - use haiku-4-5 if available (current default since Oct 2025)
            modelKey = models["haiku-4-5"] != nil ? "haiku-4-5" : "haiku"
            fallbackKey = "haiku"
        } else if modelLower.contains("sonnet") {
            modelKey = "sonnet"
            fallbackKey = "sonnet"
        } else {
            modelKey = "sonnet"  // Default
            fallbackKey = "sonnet"
        }

        // Try specific model key first, then fallback to family key
        if let pricing = models[modelKey] {
            return pricing
        }
        return models[fallbackKey] ?? defaultConfig.currentPricing[fallbackKey]!
    }

    /// Find the pricing period that contains the given date
    private func getPricingModels(for date: Date?, from config: PricingConfig) -> [String: ModelPricing] {
        guard let date = date else {
            return config.currentPricing
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)

        // Find matching period
        for period in config.history {
            let fromOK = dateString >= period.from
            let toOK = period.to == nil || dateString <= period.to!

            if fromOK && toOK {
                return period.models
            }
        }

        // Fallback to current
        return config.currentPricing
    }

    /// Calculate total cost for a model usage at a specific date
    func calculateCost(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        model: String,
        at date: Date? = nil
    ) -> Double {
        let pricing = getPricing(for: model, at: date)

        var cost: Double = 0
        cost += Double(inputTokens) * pricing.inputPerMTok / 1_000_000
        cost += Double(outputTokens) * pricing.outputPerMTok / 1_000_000
        cost += Double(cacheCreationTokens) * pricing.cacheWritePerMTok / 1_000_000
        cost += Double(cacheReadTokens) * pricing.cacheReadPerMTok / 1_000_000

        return cost
    }

    /// Get last updated date from config
    var lastUpdated: String {
        config?.lastUpdated ?? ""
    }
}

// Keep old name for compatibility
typealias BedrockPricingService = PricingService
