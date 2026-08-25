import Foundation

enum Role: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum ToolStatus: String, Codable, Sendable {
    case running
    case completed
    case error
}

struct ToolCall: Codable, Sendable {
    var id: String
    var name: String
    var input: String
    var output: String?
    var status: ToolStatus
}

struct FileRef: Codable, Sendable {
    var path: String
    var mime: String
    var filename: String?
    var url: String?
}

struct Compaction: Codable, Sendable {
    var trigger: String?
    var tokensBefore: Int?
    var tokensAfter: Int?
    var durationMs: Double?
    var preservedMessages: Int?
    var summary: String?
}

enum Part: Codable, Sendable {
    case text(String)
    case reasoning(String)
    case tool(ToolCall)
    case file(FileRef)
    case compaction(Compaction)

    private enum CodingKeys: String, CodingKey { case kind, text, tool, file, compaction }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("text", forKey: .kind)
            try c.encode(value, forKey: .text)
        case .reasoning(let value):
            try c.encode("reasoning", forKey: .kind)
            try c.encode(value, forKey: .text)
        case .tool(let call):
            try c.encode("tool", forKey: .kind)
            try c.encode(call, forKey: .tool)
        case .file(let file):
            try c.encode("file", forKey: .kind)
            try c.encode(file, forKey: .file)
        case .compaction(let value):
            try c.encode("compaction", forKey: .kind)
            try c.encode(value, forKey: .compaction)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "tool": self = .tool(try c.decode(ToolCall.self, forKey: .tool))
        case "reasoning": self = .reasoning(try c.decode(String.self, forKey: .text))
        case "file": self = .file(try c.decode(FileRef.self, forKey: .file))
        case "compaction":
            self = .compaction(try c.decode(Compaction.self, forKey: .compaction))
        default: self = .text(try c.decode(String.self, forKey: .text))
        }
    }
}

struct Message: Codable, Sendable {
    var id: String
    var role: Role
    var parts: [Part]
    var createdAt: Date
    var seconds: Double?
    var model: String?
    var usage: TokenCounts?
    var costUSD: Double?
}

struct Session: Codable, Sendable {
    var id: String
    var title: String
    var directory: String?
    var ompSessionID: String?
    var ompSessionFile: String?
    var priorOmpSessionIDs: [String]?
    var model: String
    var effort: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]
    var lastCostUSD: Double?
    var lastTokens: Int?
    var customTitle: Bool?
    var autoTitled: Bool?
    var interruption: Interruption?
    var autoResume: Bool?

    var summary: SessionSummary {
        SessionSummary(
            id: id, title: title, directory: directory, model: model, effort: effort,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

struct SessionSummary: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var directory: String?
    var model: String
    var effort: String
    var createdAt: Date
    var updatedAt: Date
    var active: Bool?
    var interrupted: Bool?
    var agents: Int?
    var agentTask: String?
    var resuming: Bool?
}

struct SubagentSummary: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var agentType: String?
    var toolUseID: String?
    var updatedAt: Date
    var active: Bool
    var completed: Bool
    var startedAt: Date?
    var toolCount: Int?
    var currentTool: String?
}

struct SubagentTranscript: Codable, Sendable {
    var id: String
    var messages: [Message]
}

struct RenameRequest: Codable, Sendable {
    var title: String
}

struct UsageSummary: Codable, Sendable {
    var costUSD: Double?
    var tokens: Int?
}

struct SendRequest: Codable, Sendable {
    var text: String
    var model: String?
    var effort: String?
    var attachments: [SendAttachment]?
}

struct SendAttachment: Codable, Sendable {
    var mime: String
    var filename: String?
    var dataBase64: String
}

struct AutoResumeRequest: Codable, Sendable {
    var enabled: Bool
}

struct CreateRequest: Codable, Sendable {
    var title: String?
    var directory: String?
    var model: String?
    var effort: String?
}

enum BridgeEvent: Codable, Sendable {
    case messageUpserted(Message)
    case partTextDelta(messageID: String, delta: String)
    case toolUpserted(messageID: String, ToolCall)
    case status(String)
    case error(String)
    case compaction(phase: String, error: String?)
    case interrupted(Interruption?)

    private enum CodingKeys: String, CodingKey {
        case type, message, messageID, delta, tool, status, error, phase, interruption
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .messageUpserted(let message):
            try c.encode("message", forKey: .type)
            try c.encode(message, forKey: .message)
        case .partTextDelta(let messageID, let delta):
            try c.encode("delta", forKey: .type)
            try c.encode(messageID, forKey: .messageID)
            try c.encode(delta, forKey: .delta)
        case .toolUpserted(let messageID, let tool):
            try c.encode("tool", forKey: .type)
            try c.encode(messageID, forKey: .messageID)
            try c.encode(tool, forKey: .tool)
        case .status(let value):
            try c.encode("status", forKey: .type)
            try c.encode(value, forKey: .status)
        case .error(let value):
            try c.encode("error", forKey: .type)
            try c.encode(value, forKey: .error)
        case .compaction(let phase, let error):
            try c.encode("compaction", forKey: .type)
            try c.encode(phase, forKey: .phase)
            try c.encodeIfPresent(error, forKey: .error)
        case .interrupted(let interruption):
            try c.encode("interrupted", forKey: .type)
            try c.encodeIfPresent(interruption, forKey: .interruption)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "message": self = .messageUpserted(try c.decode(Message.self, forKey: .message))
        case "delta":
            self = .partTextDelta(
                messageID: try c.decode(String.self, forKey: .messageID),
                delta: try c.decode(String.self, forKey: .delta))
        case "tool":
            self = .toolUpserted(
                messageID: try c.decode(String.self, forKey: .messageID),
                try c.decode(ToolCall.self, forKey: .tool))
        case "status": self = .status(try c.decode(String.self, forKey: .status))
        case "compaction":
            self = .compaction(
                phase: try c.decode(String.self, forKey: .phase),
                error: try c.decodeIfPresent(String.self, forKey: .error))
        case "interrupted":
            self = .interrupted(try c.decodeIfPresent(Interruption.self, forKey: .interruption))
        default: self = .error(try c.decode(String.self, forKey: .error))
        }
    }
}

struct FileEntry: Codable, Sendable {
    var path: String
    var name: String
    var isDirectory: Bool
}

struct FileContent: Codable, Sendable {
    var path: String
    var content: String
}

enum FileBrowsing {
    static func resolve(_ raw: String, home: String) -> String {
        if raw.isEmpty || raw == "." { return home }
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home + raw.dropFirst(1) }
        if !raw.hasPrefix("/") { return "\(home)/\(raw)" }
        return raw
    }

    static func list(_ path: String) -> [FileEntry]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            let names = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return nil }
        return names
            .filter { !$0.hasPrefix(".") }
            .map { name in
                let full = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
                var childIsDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &childIsDirectory)
                return FileEntry(path: full, name: name, isDirectory: childIsDirectory.boolValue)
            }
    }

    static func content(_ path: String, cap: Int = 262_144) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path),
            let data = try? handle.read(upToCount: cap)
        else { return nil }
        try? handle.close()
        return String(data: data, encoding: .utf8)
    }

    static func bytes(_ path: String, cap: Int = 40 * 1024 * 1024) -> Data? {
        guard readableSize(path, cap: cap) != nil else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func readableSize(_ path: String, cap: Int = 40 * 1024 * 1024) -> Int? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
            size <= cap
        else { return nil }
        return size
    }
}

struct TokenCounts: Codable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }
}

struct InterruptionProgress: Codable, Sendable, Equatable {
    var toolCount: Int = 0
    var lastTool: String?
    var filesTouched: [String] = []
    var commands: [String] = []
    var partialAnswer: String?

    var isEmpty: Bool {
        toolCount == 0 && filesTouched.isEmpty && commands.isEmpty && partialAnswer == nil
    }
}

struct Interruption: Codable, Sendable, Equatable {
    var turnID: String
    var prompt: String
    var startedAt: Date
    var detectedAt: Date
    var ompSessionFile: String?
    var progress: InterruptionProgress
    var queued: [String]
    var resumedAt: Date?

    var isResumed: Bool { resumedAt != nil }
}

struct BridgeStatus: Encodable {
    var agent: String
    var model: String
    var version: String
    var authenticated: Bool
    var proto: Int
    var epoch: String
}

struct AgentCommandDTO: Codable, Sendable {
    var name: String
    var description: String?
    var argumentHint: String?
    var source: String
    var scope: String?
}

struct SearchHitMatch: Codable, Sendable {
    var role: String
    var kind: String
    var text: String
    var at: Date?
}

struct SearchHit: Codable, Sendable {
    var sessionID: String
    var title: String
    var directory: String?
    var updatedAt: Date
    var matches: [SearchHitMatch]
    var total: Int
}

struct SearchResponse: Codable, Sendable {
    var query: String
    var hits: [SearchHit]
    var scanned: Int
    var truncated: Bool
}
