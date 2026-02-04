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

/// Message entry used during streaming line-by-line parsing
struct StreamedMessageEntry {
    let model: String
    let messageId: String
    let isBedrock: Bool
    let isClaudeAPI: Bool
    let isThisMonth: Bool
    let isToday: Bool
    let messageDate: Date?
    let input: Int
    let output: Int
    let thinkingTokens: Int
    let cacheCreate: Int
    let cacheRead: Int
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
    /// Streams file line-by-line to avoid loading entire file into memory
    func parseTranscript(at path: String) -> TranscriptUsage {
        var usage = TranscriptUsage()

        guard fileManager.fileExists(atPath: path) else {
            return usage
        }

        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return usage
        }
        defer { fileHandle.closeFile() }

        // For large files, seek to last 10MB
        let maxBytes = 10 * 1024 * 1024
        do {
            let attrs = try fileManager.attributesOfItem(atPath: path)
            let fileSize = attrs[.size] as? Int ?? 0
            if fileSize > maxBytes {
                fileHandle.seek(toFileOffset: UInt64(fileSize - maxBytes))
            }
        } catch {
            return usage
        }

        parseStreamedLines(fileHandle: fileHandle, into: &usage)
        return usage
    }

    /// Process a line of JSON data and update message maps
    /// Returns true if the line was processed
    private func processJsonLine(
        _ lineData: Data,
        monthStart: Date,
        todayStart: Date,
        messageMap: inout [String: StreamedMessageEntry],
        thinkingTokensMap: inout [String: Int]
    ) {
        guard !lineData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let messageId = message["id"] as? String else { return }

        let model = message["model"] as? String ?? "unknown"
        let isBedrock = messageId.hasPrefix("msg_bdrk_")

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

        var thinkingChars = 0
        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "thinking",
                   let thinking = block["thinking"] as? String {
                    thinkingChars += thinking.count
                }
            }
        }
        let thinkingTokens = Int(Double(thinkingChars) / 2.5)
        let existingThinking = thinkingTokensMap[messageId] ?? 0
        thinkingTokensMap[messageId] = max(existingThinking, thinkingTokens)

        if let usageData = message["usage"] as? [String: Any] {
            let hasServiceTier = usageData["service_tier"] != nil
            let isClaudeAPI = !isBedrock && !hasServiceTier
            let finalThinkingTokens = thinkingTokensMap[messageId] ?? thinkingTokens

            let entry = StreamedMessageEntry(
                model: model,
                messageId: messageId,
                isBedrock: isBedrock,
                isClaudeAPI: isClaudeAPI,
                isThisMonth: isThisMonth,
                isToday: isToday,
                messageDate: messageDate,
                input: usageData["input_tokens"] as? Int ?? 0,
                output: usageData["output_tokens"] as? Int ?? 0,
                thinkingTokens: finalThinkingTokens,
                cacheCreate: usageData["cache_creation_input_tokens"] as? Int ?? 0,
                cacheRead: usageData["cache_read_input_tokens"] as? Int ?? 0
            )
            messageMap[messageId] = entry
        }
    }

    /// Stream lines from a FileHandle and accumulate usage data
    private func parseStreamedLines(fileHandle: FileHandle, into usage: inout TranscriptUsage) {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let todayStart = calendar.startOfDay(for: now)

        var messageMap: [String: StreamedMessageEntry] = [:]
        var thinkingTokensMap: [String: Int] = [:]

        let bufferSize = 256 * 1024 // 256 KB chunks
        var remainder = Data()

        while true {
            let chunk = fileHandle.readData(ofLength: bufferSize)
            if chunk.isEmpty { break }

            remainder.append(chunk)

            while let newlineRange = remainder.range(of: Data([0x0A])) {
                let lineData = remainder.subdata(in: remainder.startIndex..<newlineRange.lowerBound)
                remainder.removeSubrange(remainder.startIndex...newlineRange.lowerBound)

                processJsonLine(lineData, monthStart: monthStart, todayStart: todayStart,
                              messageMap: &messageMap, thinkingTokensMap: &thinkingTokensMap)
            }
        }

        // Process remainder after last newline
        if !remainder.isEmpty {
            processJsonLine(remainder, monthStart: monthStart, todayStart: todayStart,
                          messageMap: &messageMap, thinkingTokensMap: &thinkingTokensMap)
        }

        // Accumulate from deduplicated messages
        accumulateMessages(messageMap, into: &usage)
    }

    /// Accumulate deduplicated messages into usage
    private func accumulateMessages(_ messageMap: [String: StreamedMessageEntry], into usage: inout TranscriptUsage) {
        let pricingService = PricingService.shared

        for (_, entry) in messageMap {
            usage.model = entry.model
            if entry.isBedrock { usage.isBedrock = true }
            if entry.isClaudeAPI { usage.isClaudeAPI = true }

            usage.inputTokens += entry.input
            usage.outputTokens += entry.output + entry.thinkingTokens
            usage.cacheCreationTokens += entry.cacheCreate
            usage.cacheReadTokens += entry.cacheRead

            let messageCost = pricingService.calculateCost(
                inputTokens: entry.input,
                outputTokens: entry.output + entry.thinkingTokens,
                cacheCreationTokens: entry.cacheCreate,
                cacheReadTokens: entry.cacheRead,
                model: entry.model,
                at: entry.messageDate
            )
            usage.calculatedCost += messageCost

            var modelData = usage.modelUsage[entry.model] ?? ModelUsageData()
            modelData.inputTokens += entry.input
            modelData.outputTokens += entry.output + entry.thinkingTokens
            modelData.cacheCreationTokens += entry.cacheCreate
            modelData.cacheReadTokens += entry.cacheRead
            usage.modelUsage[entry.model] = modelData

            if entry.isThisMonth {
                usage.monthlyInputTokens += entry.input
                usage.monthlyOutputTokens += entry.output + entry.thinkingTokens
                usage.monthlyCacheCreationTokens += entry.cacheCreate
                usage.monthlyCacheReadTokens += entry.cacheRead
                if entry.isBedrock || entry.isClaudeAPI {
                    usage.calculatedMonthlyCost += messageCost
                }

                var monthlyModelData = usage.monthlyModelUsage[entry.model] ?? ModelUsageData()
                monthlyModelData.inputTokens += entry.input
                monthlyModelData.outputTokens += entry.output + entry.thinkingTokens
                monthlyModelData.cacheCreationTokens += entry.cacheCreate
                monthlyModelData.cacheReadTokens += entry.cacheRead
                usage.monthlyModelUsage[entry.model] = monthlyModelData
            }

            if entry.isToday {
                usage.dailyInputTokens += entry.input
                usage.dailyOutputTokens += entry.output + entry.thinkingTokens
                usage.dailyCacheCreationTokens += entry.cacheCreate
                usage.dailyCacheReadTokens += entry.cacheRead
                if entry.isBedrock || entry.isClaudeAPI {
                    usage.calculatedDailyCost += messageCost
                }
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
