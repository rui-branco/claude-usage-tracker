import Foundation

struct ModelUsageData {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
}

struct TranscriptUsage {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var model: String?
    var modelUsage: [String: ModelUsageData] = [:]  // Per-model breakdown
    var isBedrock: Bool = false  // Detected from msg_bdrk_ message IDs
    var isClaudeAPI: Bool = false  // Detected from messages without service_tier (and not Bedrock)

    // Cost calculated per message with correct pricing for that time period
    var calculatedCost: Double = 0
    var calculatedMonthlyCost: Double = 0
    var calculatedDailyCost: Double = 0

    // Monthly tracking
    var monthlyInputTokens: Int = 0
    var monthlyOutputTokens: Int = 0
    var monthlyCacheCreationTokens: Int = 0
    var monthlyCacheReadTokens: Int = 0
    var monthlyModelUsage: [String: ModelUsageData] = [:]

    // Daily tracking (today)
    var dailyInputTokens: Int = 0
    var dailyOutputTokens: Int = 0
    var dailyCacheCreationTokens: Int = 0
    var dailyCacheReadTokens: Int = 0

    // All tokens used (input + output + cache)
    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var monthlyTokens: Int {
        monthlyInputTokens + monthlyOutputTokens + monthlyCacheCreationTokens + monthlyCacheReadTokens
    }

    /// Check if any Bedrock models are used (from message IDs)
    var hasBedrock: Bool {
        isBedrock || modelUsage.keys.contains { model in
            let ml = model.lowercased()
            return ml.contains("anthropic.claude") && !ml.hasPrefix("claude-")
        }
    }

    /// Check if using direct Claude API (ANTHROPIC_API_KEY)
    var hasClaudeAPI: Bool {
        isClaudeAPI
    }

    /// Check if this is a paid API project (either Bedrock or direct Claude API)
    var isPaidAPI: Bool {
        hasBedrock || hasClaudeAPI
    }

    /// Get total cost (calculated per-message with time-based pricing)
    func calculateCost() -> Double {
        return calculatedCost
    }

    /// Get monthly cost (calculated per-message with time-based pricing)
    func calculateMonthlyCost() -> Double {
        return calculatedMonthlyCost
    }
}

final class TranscriptParser: @unchecked Sendable {
    private let fileManager = FileManager.default

    /// Get the transcript path for a project and session
    func getTranscriptPath(projectPath: String, sessionId: String) -> String {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        let encodedPath = encodeProjectPath(projectPath)
        return "\(homeDir)/.claude/projects/\(encodedPath)/\(sessionId).jsonl"
    }

    /// Encode project path the same way Claude Code does (replace / and . with -)
    private func encodeProjectPath(_ path: String) -> String {
        return path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Parse transcript file and calculate total usage
    /// For large files, reads only the last portion to avoid memory issues
    func parseTranscript(at path: String) -> TranscriptUsage {
        var usage = TranscriptUsage()

        guard fileManager.fileExists(atPath: path) else {
            return usage
        }

        // For simplicity and speed, read file using shell command for large files
        // This avoids Swift FileHandle issues with large files
        let maxBytes = 10 * 1024 * 1024 // 10MB max

        do {
            let attrs = try fileManager.attributesOfItem(atPath: path)
            let fileSize = attrs[.size] as? Int ?? 0

            let content: String
            if fileSize > maxBytes {
                // Large file - use tail to read last 10MB
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
                task.arguments = ["-c", "\(maxBytes)", path]

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice

                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()

                content = String(data: data, encoding: .utf8) ?? ""
            } else {
                // Small file - read all
                guard let data = fileManager.contents(atPath: path),
                      let str = String(data: data, encoding: .utf8) else {
                    return usage
                }
                content = str
            }

            parseLines(content, into: &usage)
        } catch {
            return usage
        }

        return usage
    }

    /// Parse lines and accumulate usage data
    /// IMPORTANT: Messages appear multiple times due to streaming - deduplicate by message ID
    private func parseLines(_ content: String, into usage: inout TranscriptUsage) {
        let lines = content.components(separatedBy: "\n")

        // Get start of current month and today (in UTC to match transcript timestamps)
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let todayStart = calendar.startOfDay(for: now)

        // First pass: collect final version of each message (by ID)
        // Messages stream incrementally - only the LAST entry per ID has final token counts
        struct MessageEntry {
            let model: String
            let messageId: String
            let isBedrock: Bool
            let isClaudeAPI: Bool  // Direct Claude API (no service_tier, not Bedrock)
            let isThisMonth: Bool
            let isToday: Bool
            let messageDate: Date?  // For time-based pricing
            let input: Int
            let output: Int
            let cacheCreate: Int
            let cacheRead: Int
        }
        var messageMap: [String: MessageEntry] = [:]

        for line in lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8) else { continue }

            do {
                if let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   json["type"] as? String == "assistant",
                   let message = json["message"] as? [String: Any],
                   let messageId = message["id"] as? String {

                    let model = message["model"] as? String ?? "unknown"
                    let isBedrock = messageId.hasPrefix("msg_bdrk_")

                    // Extract timestamp
                    var isThisMonth = false
                    var isToday = false
                    var messageDate: Date?
                    if let timestamp = json["timestamp"] as? String {
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        var date = formatter.date(from: timestamp)
                        if date == nil {
                            formatter.formatOptions = [.withInternetDateTime]
                            date = formatter.date(from: timestamp)
                        }
                        if let date = date {
                            isThisMonth = date >= monthStart
                            isToday = date >= todayStart
                            messageDate = date
                        }
                    }

                    // Extract usage and detect API type
                    if let usageData = message["usage"] as? [String: Any] {
                        // Detect direct Claude API: no service_tier and not Bedrock
                        // Subscription has service_tier: "standard"
                        // Bedrock has msg_bdrk_ prefix
                        // Direct API has neither
                        let hasServiceTier = usageData["service_tier"] != nil
                        let isClaudeAPI = !isBedrock && !hasServiceTier

                        let entry = MessageEntry(
                            model: model,
                            messageId: messageId,
                            isBedrock: isBedrock,
                            isClaudeAPI: isClaudeAPI,
                            isThisMonth: isThisMonth,
                            isToday: isToday,
                            messageDate: messageDate,
                            input: usageData["input_tokens"] as? Int ?? 0,
                            output: usageData["output_tokens"] as? Int ?? 0,
                            cacheCreate: usageData["cache_creation_input_tokens"] as? Int ?? 0,
                            cacheRead: usageData["cache_read_input_tokens"] as? Int ?? 0
                        )
                        // Keep last entry per message ID (has final token count)
                        messageMap[messageId] = entry
                    }
                }
            } catch {
                continue
            }
        }

        // Second pass: accumulate from deduplicated messages
        let pricingService = PricingService.shared

        for (_, entry) in messageMap {
            usage.model = entry.model
            if entry.isBedrock {
                usage.isBedrock = true
            }
            if entry.isClaudeAPI {
                usage.isClaudeAPI = true
            }

            // Accumulate totals
            usage.inputTokens += entry.input
            usage.outputTokens += entry.output
            usage.cacheCreationTokens += entry.cacheCreate
            usage.cacheReadTokens += entry.cacheRead

            // Calculate cost using pricing for this message's date
            let messageCost = pricingService.calculateCost(
                inputTokens: entry.input,
                outputTokens: entry.output,
                cacheCreationTokens: entry.cacheCreate,
                cacheReadTokens: entry.cacheRead,
                model: entry.model,
                at: entry.messageDate
            )
            usage.calculatedCost += messageCost

            // Track per-model usage
            var modelData = usage.modelUsage[entry.model] ?? ModelUsageData()
            modelData.inputTokens += entry.input
            modelData.outputTokens += entry.output
            modelData.cacheCreationTokens += entry.cacheCreate
            modelData.cacheReadTokens += entry.cacheRead
            usage.modelUsage[entry.model] = modelData

            // Track monthly usage
            if entry.isThisMonth {
                usage.monthlyInputTokens += entry.input
                usage.monthlyOutputTokens += entry.output
                usage.monthlyCacheCreationTokens += entry.cacheCreate
                usage.monthlyCacheReadTokens += entry.cacheRead
                usage.calculatedMonthlyCost += messageCost

                var monthlyModelData = usage.monthlyModelUsage[entry.model] ?? ModelUsageData()
                monthlyModelData.inputTokens += entry.input
                monthlyModelData.outputTokens += entry.output
                monthlyModelData.cacheCreationTokens += entry.cacheCreate
                monthlyModelData.cacheReadTokens += entry.cacheRead
                usage.monthlyModelUsage[entry.model] = monthlyModelData
            }

            // Track daily usage (today)
            if entry.isToday {
                usage.dailyInputTokens += entry.input
                usage.dailyOutputTokens += entry.output
                usage.dailyCacheCreationTokens += entry.cacheCreate
                usage.dailyCacheReadTokens += entry.cacheRead
                usage.calculatedDailyCost += messageCost
            }
        }
    }

    /// Get total usage for a project - parses ALL transcripts
    func getTotalUsage(projectPath: String) -> TranscriptUsage? {
        let projectDir = getProjectDirectory(projectPath: projectPath)

        guard fileManager.fileExists(atPath: projectDir) else { return nil }

        do {
            let files = try fileManager.contentsOfDirectory(atPath: projectDir)
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }

            guard !jsonlFiles.isEmpty else { return nil }

            var combinedUsage = TranscriptUsage()

            for file in jsonlFiles {
                let fullPath = "\(projectDir)/\(file)"
                let fileUsage = parseTranscript(at: fullPath)

                // Accumulate totals
                combinedUsage.inputTokens += fileUsage.inputTokens
                combinedUsage.outputTokens += fileUsage.outputTokens
                combinedUsage.cacheCreationTokens += fileUsage.cacheCreationTokens
                combinedUsage.cacheReadTokens += fileUsage.cacheReadTokens

                // Accumulate costs (calculated with time-based pricing)
                combinedUsage.calculatedCost += fileUsage.calculatedCost
                combinedUsage.calculatedMonthlyCost += fileUsage.calculatedMonthlyCost
                combinedUsage.calculatedDailyCost += fileUsage.calculatedDailyCost

                // Track API types
                if fileUsage.isBedrock { combinedUsage.isBedrock = true }
                if fileUsage.isClaudeAPI { combinedUsage.isClaudeAPI = true }

                // Accumulate monthly
                combinedUsage.monthlyInputTokens += fileUsage.monthlyInputTokens
                combinedUsage.monthlyOutputTokens += fileUsage.monthlyOutputTokens
                combinedUsage.monthlyCacheCreationTokens += fileUsage.monthlyCacheCreationTokens
                combinedUsage.monthlyCacheReadTokens += fileUsage.monthlyCacheReadTokens

                // Accumulate daily
                combinedUsage.dailyInputTokens += fileUsage.dailyInputTokens
                combinedUsage.dailyOutputTokens += fileUsage.dailyOutputTokens
                combinedUsage.dailyCacheCreationTokens += fileUsage.dailyCacheCreationTokens
                combinedUsage.dailyCacheReadTokens += fileUsage.dailyCacheReadTokens

                // Merge model usage
                for (model, data) in fileUsage.modelUsage {
                    var existing = combinedUsage.modelUsage[model] ?? ModelUsageData()
                    existing.inputTokens += data.inputTokens
                    existing.outputTokens += data.outputTokens
                    existing.cacheCreationTokens += data.cacheCreationTokens
                    existing.cacheReadTokens += data.cacheReadTokens
                    combinedUsage.modelUsage[model] = existing
                }

                // Merge monthly model usage
                for (model, data) in fileUsage.monthlyModelUsage {
                    var existing = combinedUsage.monthlyModelUsage[model] ?? ModelUsageData()
                    existing.inputTokens += data.inputTokens
                    existing.outputTokens += data.outputTokens
                    existing.cacheCreationTokens += data.cacheCreationTokens
                    existing.cacheReadTokens += data.cacheReadTokens
                    combinedUsage.monthlyModelUsage[model] = existing
                }

                combinedUsage.model = fileUsage.model
            }

            return combinedUsage
        } catch {
            return nil
        }
    }

    /// Get real-time usage for a project - ALWAYS uses most recent transcript
    func getRealtimeUsage(projectPath: String, sessionId: String?) -> TranscriptUsage? {
        let projectDir = getProjectDirectory(projectPath: projectPath)

        // Always find the most recently modified transcript (active session)
        guard let mostRecentTranscript = findMostRecentTranscript(in: projectDir) else {
            return nil
        }
        return parseTranscript(at: mostRecentTranscript)
    }

    /// Get the project directory path
    private func getProjectDirectory(projectPath: String) -> String {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        let encodedPath = encodeProjectPath(projectPath)
        return "\(homeDir)/.claude/projects/\(encodedPath)"
    }

    /// Find the most recently modified transcript file in a directory
    private func findMostRecentTranscript(in directory: String) -> String? {
        guard fileManager.fileExists(atPath: directory) else { return nil }

        do {
            let files = try fileManager.contentsOfDirectory(atPath: directory)
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }

            var mostRecent: (path: String, date: Date)?

            for file in jsonlFiles {
                let fullPath = "\(directory)/\(file)"
                if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    if mostRecent == nil || modDate > mostRecent!.date {
                        mostRecent = (fullPath, modDate)
                    }
                }
            }

            return mostRecent?.path
        } catch {
            return nil
        }
    }
}
