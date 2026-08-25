import Foundation

struct SpendTurnDTO: Codable, Sendable {
    var at: Date
    var seconds: Double?
    var model: String?
    var calls: Int
    var tokens: TokenCounts
    var costUSD: Double
    var prompt: String?
}

struct SpendModelDTO: Codable, Sendable {
    var model: String
    var turns: Int
    var tokens: TokenCounts
    var costUSD: Double
}

struct SessionSpendReportDTO: Codable, Sendable {
    var costUSD: Double
    var tokens: TokenCounts
    var turns: [SpendTurnDTO]
    var byModel: [SpendModelDTO]
    var startedAt: Date?
    var endedAt: Date?
    var estimated: Bool
}

enum SpendAnalytics {
    static func report(
        title: String, turns: [TurnRecord], totals: (costUSD: Double, tokens: TokenCounts)
    ) -> SessionSpendReportDTO {
        var byModel: [String: SpendModelDTO] = [:]
        let dtos = turns.map { turn in
            let key = turn.model ?? "unknown"
            var entry = byModel[key] ?? SpendModelDTO(model: key, turns: 0, tokens: TokenCounts(), costUSD: 0)
            entry.turns += 1
            entry.tokens = entry.tokens + turn.tokens
            entry.costUSD += turn.costUSD
            byModel[key] = entry
            return SpendTurnDTO(
                at: turn.at, seconds: turn.seconds, model: turn.model, calls: turn.calls,
                tokens: turn.tokens, costUSD: turn.costUSD, prompt: turn.prompt)
        }
        return SessionSpendReportDTO(
            costUSD: totals.costUSD, tokens: totals.tokens, turns: dtos.reversed(),
            byModel: byModel.values.sorted { $0.costUSD > $1.costUSD },
            startedAt: turns.first?.at, endedAt: turns.last?.at, estimated: true)
    }
}

struct AnalyticsTotalsDTO: Codable, Sendable {
    var costUSD: Double
    var tokens: Int
    var turns: Int
    var toolCalls: Int
    var sessions: Int
    var activeDays: Int
}

struct AnalyticsDayDTO: Codable, Sendable {
    var day: String
    var costUSD: Double
    var tokens: Int
    var turns: Int
    var toolCalls: Int
    var sessions: Int
}

struct AnalyticsProjectDTO: Codable, Sendable {
    var directory: String
    var name: String
    var sessions: Int
    var turns: Int
    var costUSD: Double
    var tokens: Int
}

struct AnalyticsToolDTO: Codable, Sendable {
    var name: String
    var calls: Int
}

struct AnalyticsCompactionsDTO: Codable, Sendable {
    var count: Int
    var reclaimedTokens: Int
}

struct AnalyticsSubagentsDTO: Codable, Sendable {
    var runs: Int
    var tokens: Int
    var costUSD: Double
}

struct AnalyticsRecordsDTO: Codable, Sendable {
    var busiestDay: String?
    var priciestSession: String?
    var priciestTurn: Double?
    var longestTurn: Double?
    var streakDays: Int?
}

struct UsageAnalyticsReportDTO: Codable, Sendable {
    var since: Date
    var generatedAt: Date
    var days: Int
    var estimated: Bool
    var totals: AnalyticsTotalsDTO
    var daily: [AnalyticsDayDTO]
    var models: [SpendModelDTO]
    var projects: [AnalyticsProjectDTO]
    var tools: [AnalyticsToolDTO]
    var hourTurns: [Int]
    var hourCostUSD: [Double]
    var cacheSavedUSD: Double
    var compactions: AnalyticsCompactionsDTO
    var subagents: AnalyticsSubagentsDTO
    var records: AnalyticsRecordsDTO
}

enum AnalyticsBuilder {
    static func build(config: Config, liveSessions: [OmpSession], days: Int) async -> UsageAnalyticsReportDTO {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        struct TurnFacts {
            var at: Date
            var model: String?
            var tokens = TokenCounts()
            var costUSD = 0.0
            var toolCalls = 0
            var seconds: Double?
            var prompt: String?
        }

        var perDirectory: [String: (sessions: Int, turns: Int, costUSD: Double, tokens: Int)] = [:]
        var allTurns: [TurnFacts] = []
        var toolCounts: [String: Int] = [:]
        var sessionCount = 0

        func absorb(messages: [Message], turns: [TurnRecord], directory: String?) {
            sessionCount += 1
            let dir = directory ?? "unknown"
            var entry =
                perDirectory[dir]
                ?? (sessions: 0, turns: 0, costUSD: 0.0, tokens: 0)
            entry.sessions += 1

            if !turns.isEmpty {
                for turn in turns where turn.at >= since {
                    entry.turns += 1
                    entry.costUSD += turn.costUSD
                    entry.tokens += turn.tokens.total
                    var facts = TurnFacts(at: turn.at, model: turn.model)
                    facts.tokens = turn.tokens
                    facts.costUSD = turn.costUSD
                    facts.toolCalls = max(turn.calls - 1, 0)
                    facts.seconds = turn.seconds
                    facts.prompt = turn.prompt
                    allTurns.append(facts)
                }
            } else {
                var openTurn = false
                for message in messages where message.createdAt >= since {
                    switch message.role {
                    case .user:
                        openTurn = true
                        entry.turns += 1
                        var facts = TurnFacts(at: message.createdAt, model: nil)
                        facts.prompt = message.parts.compactMap { part in
                            if case .text(let text) = part { return text }
                            return nil
                        }.first
                        allTurns.append(facts)
                    case .assistant:
                        if openTurn, let index = allTurns.indices.last {
                            allTurns[index].tokens = allTurns[index].tokens + (message.usage ?? TokenCounts())
                            allTurns[index].costUSD += message.costUSD ?? 0
                            for part in message.parts {
                                if case .tool(let call) = part {
                                    allTurns[index].toolCalls += 1
                                    toolCounts[call.name, default: 0] += 1
                                }
                            }
                            if let model = message.model { allTurns[index].model = model }
                        }
                    case .system:
                        break
                    }
                }
            }
            perDirectory[dir] = entry
        }

        for session in liveSessions {
            await absorb(
                messages: session.snapshotMessages(), turns: session.turnsSnapshot(),
                directory: session.directoryPath())
        }

        let hidden: [String] = []
        let discovered = Discovery.scan(root: config.ompSessionsRoot, hidden: hidden, claimedFiles: [])
        let claimedLiveFiles = await {
            var files: Set<String> = []
            for session in liveSessions {
                if let file = await session.sessionFile() { files.insert(file) }
            }
            return files
        }()
        for item in discovered where claimedLiveFiles.contains(item.file) == false && item.updatedAt >= since {
            let loaded = TranscriptLoader.load(sessionFile: item.file)
            absorb(messages: loaded.messages, turns: [], directory: loaded.cwd)
        }

        var dailyMap: [String: AnalyticsDayDTO] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var hourTurns = Array(repeating: 0, count: 24)
        var hourCost = Array(repeating: 0.0, count: 24)
        var byModel: [String: SpendModelDTO] = [:]

        for turn in allTurns {
            let key = dayFormatter.string(from: turn.at)
            var day = dailyMap[key] ?? AnalyticsDayDTO(day: key, costUSD: 0, tokens: 0, turns: 0, toolCalls: 0, sessions: 0)
            day.costUSD += turn.costUSD
            day.tokens += turn.tokens.total
            day.turns += 1
            day.toolCalls += turn.toolCalls
            dailyMap[key] = day
            hourTurns[calendar.component(.hour, from: turn.at)] += 1
            hourCost[calendar.component(.hour, from: turn.at)] += turn.costUSD
            let modelKey = turn.model ?? "unknown"
            var entry = byModel[modelKey] ?? SpendModelDTO(model: modelKey, turns: 0, tokens: TokenCounts(), costUSD: 0)
            entry.turns += 1
            entry.tokens = entry.tokens + turn.tokens
            entry.costUSD += turn.costUSD
            byModel[modelKey] = entry
        }
        let sortedDays = dailyMap.values.sorted { $0.day < $1.day }
        let totalTokens = allTurns.reduce(0) { $0 + $1.tokens.total }
        let totalCost = allTurns.reduce(0) { $0 + $1.costUSD }
        let totalTools = allTurns.reduce(0) { $0 + $1.toolCalls }
        let activeDays = dailyMap.count
        let busiest = sortedDays.max { $0.turns < $1.turns }?.day
        let priciestSession = perDirectory.max { $0.value.costUSD < $1.value.costUSD }?.key
        let priciestTurn = allTurns.map(\.costUSD).max()
        let longestTurn = allTurns.compactMap(\.seconds).max()

        var streak = 0
        if !sortedDays.isEmpty {
            var cursor = Date()
            for _ in 0..<days {
                let key = dayFormatter.string(from: cursor)
                if dailyMap[key]?.turns ?? 0 > 0 {
                    streak += 1
                } else if cursor < sortedDays[sortedDays.count - 1].day.dayAsDate() {
                    break
                }
                cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            }
        }

        return UsageAnalyticsReportDTO(
            since: since, generatedAt: Date(), days: days, estimated: true,
            totals: AnalyticsTotalsDTO(
                costUSD: totalCost, tokens: totalTokens, turns: allTurns.count,
                toolCalls: totalTools, sessions: sessionCount, activeDays: activeDays),
            daily: sortedDays,
            models: byModel.values.sorted { $0.costUSD > $1.costUSD },
            projects: perDirectory
                .map { dir, entry in
                    AnalyticsProjectDTO(
                        directory: dir, name: (dir as NSString).lastPathComponent,
                        sessions: entry.sessions, turns: entry.turns, costUSD: entry.costUSD,
                        tokens: entry.tokens)
                }
                .sorted { $0.costUSD > $1.costUSD },
            tools: toolCounts.map { AnalyticsToolDTO(name: $0.key, calls: $0.value) }
                .sorted { $0.calls > $1.calls },
            hourTurns: hourTurns, hourCostUSD: hourCost,
            cacheSavedUSD: 0,
            compactions: AnalyticsCompactionsDTO(count: 0, reclaimedTokens: 0),
            subagents: AnalyticsSubagentsDTO(runs: 0, tokens: 0, costUSD: 0),
            records: AnalyticsRecordsDTO(
                busiestDay: busiest, priciestSession: priciestSession,
                priciestTurn: priciestTurn, longestTurn: longestTurn, streakDays: streak))
    }
}

extension String {
    func dayAsDate() -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: self) ?? Date.distantPast
    }
}
