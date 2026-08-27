import Foundation

struct LoadedTranscript {
    var sessionID: String?
    var cwd: String?
    var title: String?
    var updatedAt: Date?
    var firstUserText: String?
    var messages: [Message] = []
    var model: String?
    var effort: String?
}

enum TranscriptLoader {
    static func load(sessionFile: String) -> LoadedTranscript {
        var result = LoadedTranscript()
        guard let raw = FileManager.default.contents(atPath: sessionFile) else { return result }
        result.updatedAt = mtime(sessionFile)
        struct OpenCall {
            let id: String
            let name: String
            let input: String
        }
        var openCalls: [String] = []
        for line in raw.split(separator: UInt8(0x0A)) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) else { continue }
            let value = JSONValue.from(obj)
            switch value["type"]?.stringValue {
            case "session":
                result.sessionID = value["id"]?.stringValue
                result.cwd = value["cwd"]?.stringValue
                if let ts = value["timestamp"]?.stringValue, let parsed = isoDate(ts),
                    result.updatedAt == nil || parsed > (result.updatedAt ?? .distantPast)
                {
                    result.updatedAt = parsed
                }
            case "model_change":
                if let model = value["model"]?.stringValue { result.model = model }
            case "thinking_level_change":
                if let level = value["thinkingLevel"]?.stringValue { result.effort = level }
            case "title":
                if let title = value["title"]?.stringValue, !title.isEmpty { result.title = title }
            case "message":
                guard let message = value["message"], let role = message["role"]?.stringValue else { continue }
                let timestamp =
                    message["timestamp"].flatMap { $0.doubleValue }
                    .map { Date(timeIntervalSince1970: $0 / 1000) }
                    ?? isoDate(value["timestamp"]?.stringValue ?? "") ?? Date()
                switch role {
                case "user":
                    let texts = blocks(message["content"]).compactMap { block -> String? in
                        if block["type"]?.stringValue == "text" { return block["text"]?.stringValue }
                        return nil
                    }
                    let text = texts.joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    if result.firstUserText == nil { result.firstUserText = text }
                    result.messages.append(
                        Message(
                            id: "u-\(value["id"]?.stringValue ?? UUID().uuidString)", role: .user,
                            parts: [.text(text)], createdAt: timestamp, seconds: nil, model: nil,
                            usage: nil, costUSD: nil))
                case "assistant":
                    var parts: [Part] = []
                    for block in blocks(message["content"]) {
                        switch block["type"]?.stringValue {
                        case "text":
                            if let text = block["text"]?.stringValue, !text.isEmpty {
                                parts.append(.text(text))
                            }
                        case "thinking":
                            if let text = block["thinking"]?.stringValue, !text.isEmpty {
                                parts.append(.reasoning(text))
                            }
                        case "toolCall":
                            if let callID = block["id"]?.stringValue {
                                let name = block["name"]?.stringValue ?? ""
                                let input = OmpSession.serializeArguments(block["arguments"])
                                parts.append(
                                    .tool(ToolCall(id: callID, name: name, input: input, status: .running)))
                                openCalls.append(callID)
                            }
                        default:
                            break
                        }
                    }
                    guard !parts.isEmpty else { continue }
                    let usage = message["usage"]
                    let counts = TokenCounts(
                        input: usage?["input"]?.intValue ?? 0,
                        output: usage?["output"]?.intValue ?? 0,
                        cacheRead: usage?["cacheRead"]?.intValue ?? 0,
                        cacheWrite5m: usage?["cacheWrite"]?.intValue ?? 0, cacheWrite1h: 0)
                    result.messages.append(
                        Message(
                            id: "a-\(value["id"]?.stringValue ?? UUID().uuidString)",
                            role: .assistant, parts: parts, createdAt: timestamp, seconds: nil,
                            model: message["model"]?.stringValue, usage: counts,
                            costUSD: usage?["cost"]?["total"]?.doubleValue))
                case "toolResult":
                    guard let callID = message["toolCallId"]?.stringValue ?? message["toolCallID"]?.stringValue else { continue }
                    let output = blocks(message["content"]).compactMap { block -> String? in
                        if block["type"]?.stringValue == "text" { return block["text"]?.stringValue }
                        return nil
                    }.joined()
                    let isError = message["isError"]?.boolValue ?? false
                    if let index = result.messages.lastIndex(where: { msg in
                        msg.parts.contains { part in
                            if case .tool(let call) = part { return call.id == callID && call.status == .running }
                            return false
                        }
                    }) {
                        result.messages[index].parts = result.messages[index].parts.map { part in
                            if case .tool(var call) = part, call.id == callID, call.status == .running {
                                call.status = isError ? .error : .completed
                                call.output = String(output.prefix(131_072))
                                return .tool(call)
                            }
                            return part
                        }
                        openCalls.removeAll { $0 == callID }
                    }
                default:
                    break
                }
            default:
                break
            }
        }
        return result
    }

    private static func blocks(_ value: JSONValue?) -> [JSONValue] {
        value?.arrayValue ?? []
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
