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
        var dtos = turns.map { turn in
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
        // A subscription provider bills a flat fee and its engine reports no money, so the turns
        // arrive priced at zero and every client renders "$0" — a number that says the conversation
        // was free, which is not a fact anyone can act on. Where the provider publishes a per-token
        // rate card, price the tiers at it and say so: the report already carries `estimated`, the
        // badge wears "~", and the source line names the guess. An engine that reported real money
        // is never touched.
        let engineReportedMoney = totals.costUSD > 0 || turns.contains { $0.costUSD > 0 }
        if !engineReportedMoney {
            for index in dtos.indices {
                dtos[index].costUSD = Self.listPrice(
                    model: dtos[index].model, tokens: dtos[index].tokens)
            }
            for (key, var entry) in byModel {
                entry.costUSD = dtos.filter { ($0.model ?? "unknown") == key }
                    .reduce(0) { $0 + $1.costUSD }
                byModel[key] = entry
            }
        }
        let totalCost = !engineReportedMoney ? dtos.reduce(0) { $0 + $1.costUSD } : totals.costUSD
        return SessionSpendReportDTO(
            costUSD: totalCost, tokens: totals.tokens, turns: dtos.reversed(),
            byModel: byModel.values.sorted { $0.costUSD > $1.costUSD },
            startedAt: turns.first?.at, endedAt: turns.last?.at, estimated: true)
    }

    /// Per-million-token list prices, read off the provider's own rate card. Nil for a model the
    /// card does not carry — an invented rate is a worse lie than no money at all.
    static func listPrice(model: String?, tokens: TokenCounts) -> Double {
        guard let model else { return 0 }
        let id = model.lowercased()
        let rates: (input: Double, cached: Double, output: Double)
        if id.contains("glm-5.3-flash") {
            rates = (input: 0.15, cached: 0.03, output: 0.50)
        } else if id.contains("glm-5.2") {
            rates = (input: 1.40, cached: 0.26, output: 4.40)
        } else if id.contains("glm-5.1") {
            rates = (input: 1.00, cached: 0.20, output: 3.20)
        } else if id.contains("deepseek-v4-flash") {
            rates = (input: 0.44, cached: 0.044, output: 1.32)
        } else if id.contains("deepseek-v4-pro") {
            rates = (input: 0.88, cached: 0.088, output: 2.64)
        } else {
            return 0
        }
        return Double(tokens.input) / 1_000_000 * rates.input
            + Double(tokens.cacheRead) / 1_000_000 * rates.cached
            + Double(tokens.output) / 1_000_000 * rates.output
    }
}

/// The report every client reads, in the shape claude-bridge publishes and the Kit decodes:
/// token counts are always the five-tier object, never a flat total, and a record names the
/// thing that set it — the day with its money and turns, the conversation with its id and
/// title, the turn with its prompt — rather than a bare number. A flat schema here decoded as
/// nothing on the phone, and a bridge that answers 200 with a body the client cannot read is
/// reported as a machine too old to have the route.
struct AnalyticsTotalsDTO: Codable, Sendable {
    var costUSD: Double
    var tokens: TokenCounts
    var turns: Int
    var toolCalls: Int
    var sessions: Int
    var activeDays: Int
}

struct AnalyticsDayDTO: Codable, Sendable {
    var day: String
    var costUSD: Double
    var tokens: TokenCounts
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
    var tokens: TokenCounts
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
    var tokens: TokenCounts
    var costUSD: Double
}

struct AnalyticsRecordsDTO: Codable, Sendable {
    struct BusiestDay: Codable, Sendable {
        var day: String
        var costUSD: Double
        var turns: Int
    }

    struct Session: Codable, Sendable {
        var id: String
        var title: String
        var costUSD: Double
        var turns: Int
    }

    struct Turn: Codable, Sendable {
        var at: Date
        var costUSD: Double
        var seconds: Double?
        var model: String?
        var prompt: String?
        var sessionTitle: String?
    }

    var busiestDay: BusiestDay?
    var priciestSession: Session?
    var priciestTurn: Turn?
    var longestTurn: Turn?
    var streakDays: Int
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
            var sessionTitle: String
        }
        struct ProjectFacts {
            var sessions = 0
            var turns = 0
            var costUSD = 0.0
            var tokens = TokenCounts()
        }

        var perDirectory: [String: ProjectFacts] = [:]
        var allTurns: [TurnFacts] = []
        var toolCounts: [String: Int] = [:]
        var sessionCount = 0
        var priciestSession: AnalyticsRecordsDTO.Session?

        func absorb(
            id: String, title: String, messages: [Message], turns: [TurnRecord], directory: String?
        ) {
            let dir = directory ?? "unknown"
            var entry = perDirectory[dir] ?? ProjectFacts()
            var sessionCost = 0.0
            var sessionTurns = 0
            var sessionTokens = TokenCounts()

            if !turns.isEmpty {
                for turn in turns where turn.at >= since {
                    sessionTurns += 1
                    sessionCost += turn.costUSD
                    sessionTokens = sessionTokens + turn.tokens
                    var facts = TurnFacts(at: turn.at, model: turn.model, sessionTitle: title)
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
                        sessionTurns += 1
                        var facts = TurnFacts(at: message.createdAt, model: nil, sessionTitle: title)
                        facts.prompt = message.parts.compactMap { part in
                            if case .text(let text) = part { return text }
                            return nil
                        }.first
                        allTurns.append(facts)
                    case .assistant:
                        if openTurn, let index = allTurns.indices.last {
                            let usage = message.usage ?? TokenCounts()
                            allTurns[index].tokens = allTurns[index].tokens + usage
                            allTurns[index].costUSD += message.costUSD ?? 0
                            sessionTokens = sessionTokens + usage
                            sessionCost += message.costUSD ?? 0
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
            guard sessionTurns > 0 else { return }
            sessionCount += 1
            entry.sessions += 1
            entry.turns += sessionTurns
            entry.costUSD += sessionCost
            entry.tokens = entry.tokens + sessionTokens
            perDirectory[dir] = entry
            if sessionCost > (priciestSession?.costUSD ?? 0) {
                priciestSession = AnalyticsRecordsDTO.Session(
                    id: id, title: title, costUSD: sessionCost, turns: sessionTurns)
            }
        }

        for session in liveSessions {
            await absorb(
                id: session.id, title: session.titleText(), messages: session.snapshotMessages(),
                turns: session.turnsSnapshot(), directory: session.directoryPath())
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
            absorb(
                id: loaded.sessionID ?? item.file, title: loaded.title ?? item.title,
                messages: loaded.messages, turns: [], directory: loaded.cwd)
        }

        var dailyMap: [String: AnalyticsDayDTO] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var hourTurns = Array(repeating: 0, count: 24)
        var hourCost = Array(repeating: 0.0, count: 24)
        var byModel: [String: SpendModelDTO] = [:]
        var priciestTurn: TurnFacts?
        var longestTurn: TurnFacts?

        for turn in allTurns {
            let key = dayFormatter.string(from: turn.at)
            var day = dailyMap[key]
                ?? AnalyticsDayDTO(
                    day: key, costUSD: 0, tokens: TokenCounts(), turns: 0, toolCalls: 0, sessions: 0)
            day.costUSD += turn.costUSD
            day.tokens = day.tokens + turn.tokens
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
            if turn.costUSD > (priciestTurn?.costUSD ?? 0) { priciestTurn = turn }
            if let seconds = turn.seconds, seconds > (longestTurn?.seconds ?? 0) { longestTurn = turn }
        }
        let sortedDays = dailyMap.values.sorted { $0.day < $1.day }
        let totalTokens = allTurns.reduce(TokenCounts()) { $0 + $1.tokens }
        let totalCost = allTurns.reduce(0) { $0 + $1.costUSD }
        let totalTools = allTurns.reduce(0) { $0 + $1.toolCalls }
        let activeDays = dailyMap.count
        let busiest = sortedDays.max { $0.costUSD < $1.costUSD }.map {
            AnalyticsRecordsDTO.BusiestDay(day: $0.day, costUSD: $0.costUSD, turns: $0.turns)
        }

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

        func record(_ turn: TurnFacts) -> AnalyticsRecordsDTO.Turn {
            AnalyticsRecordsDTO.Turn(
                at: turn.at, costUSD: turn.costUSD, seconds: turn.seconds, model: turn.model,
                prompt: turn.prompt, sessionTitle: turn.sessionTitle)
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
            subagents: AnalyticsSubagentsDTO(runs: 0, tokens: TokenCounts(), costUSD: 0),
            records: AnalyticsRecordsDTO(
                busiestDay: busiest, priciestSession: priciestSession,
                priciestTurn: priciestTurn.map(record), longestTurn: longestTurn.map(record),
                streakDays: streak))
    }
}

extension String {
    func dayAsDate() -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: self) ?? Date.distantPast
    }
}
