import Foundation

struct OmpRPCResponse: Sendable {
    let command: String
    let success: Bool
    let error: String?
    let errorCode: String?
    let data: JSONValue?
}

enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var intValue: Int? {
        doubleValue.map { Int($0) }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: .null
        case let b as Bool: .bool(b)
        case let n as NSNumber: .number(n.doubleValue)
        case let s as String: .string(s)
        case let a as [Any]: .array(a.map { from($0) })
        case let o as [String: Any]:
            .object(o.mapValues { from($0) })
        default: .string(String(describing: any))
        }
    }

    var raw: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map { $0.raw }
        case .object(let o): o.mapValues { $0.raw }
        }
    }
}

enum OmpInboundFrame: Sendable {
    case ready(protocolVersions: [Int], maxFrameBytes: Int)
    case response(OmpRPCResponse)
    case event(JSONValue)
}

actor OmpProcess {
    private let ompBin: String
    private let directory: String
    private let extraEnv: [String: String]
    private let onEvent: @Sendable (JSONValue) async -> Void
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [String: CheckedContinuation<OmpRPCResponse, Never>] = [:]
    private var chunks: [String: (count: Int, parts: [Int: Data], bytes: Int)] = [:]
    private var reassemblyLimit = 67_108_864
    private(set) var protocolVersion = 1
    private(set) var isRunning = false
    private var nextRequestID = 0

    init(
        ompBin: String, directory: String, extraEnv: [String: String] = [:],
        onEvent: @escaping @Sendable (JSONValue) async -> Void
    ) {
        self.ompBin = ompBin
        self.directory = directory
        self.extraEnv = extraEnv
        self.onEvent = onEvent
    }

    func start() throws {
        guard !isRunning else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ompBin)
        p.arguments = ["--mode", "rpc"]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        env.merge(extraEnv) { _, new in new }
        p.environment = env
        let outPipe = Pipe()
        let inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardInput = inPipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            Task { await self?.terminated() }
        }
        try p.run()
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        isRunning = true
        let reader = LineReader(handle: outPipe.fileHandleForReading)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.readLoop(reader)
        }
    }

    private func terminated() {
        guard isRunning else { return }
        isRunning = false
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(
                returning: OmpRPCResponse(
                    command: "process", success: false,
                    error: "The oh-my-pi process exited", errorCode: nil, data: nil))
        }
    }

    func stop() {
        guard let process, isRunning else { return }
        try? stdinHandle?.close()
        stdinHandle = nil
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning { process.terminate() }
        isRunning = false
    }

    private func readLoop(_ reader: LineReader) async {
        while let line = reader.nextLine() {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            let value = JSONValue.from(obj)
            await handleLine(value)
        }
        await terminated()
    }

    private func handleLine(_ value: JSONValue) async {
        switch value["type"]?.stringValue {
        case "ready":
            let versions = (value["supportedProtocolVersions"]?.arrayValue ?? []).compactMap(\.intValue)
            reassemblyLimit = value["maxReassembledFrameBytes"]?.intValue ?? reassemblyLimit
            protocolVersion = versions.max() ?? 1
            if protocolVersion >= 2 {
                _ = sendRaw([
                    "id": "negotiate-\(UUID().uuidString.prefix(8))",
                    "type": "negotiate_protocol",
                    "protocolVersion": 2,
                ])
            }
        case "rpc_chunk":
            reassemble(value)
        case "response":
            let response = OmpRPCResponse(
                command: value["command"]?.stringValue ?? "",
                success: value["success"]?.boolValue ?? false,
                error: value["error"]?.stringValue,
                errorCode: value["code"]?.stringValue,
                data: value["data"])
            if let id = value["id"]?.stringValue, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(returning: response)
            }
        case .some(let kind):
            if kind == "extension_ui_request" || kind == "host_tool_call"
                || kind == "host_uri_request" || kind.hasSuffix("_lifecycle")
                || kind.hasSuffix("_progress") || kind.hasSuffix("_event")
                || kind == "notice" || kind == "prompt_result" || kind == "command_output"
                || kind == "available_commands_update" || kind == "extension_error"
                || kind.hasPrefix("agent_") || kind.hasPrefix("turn_")
                || kind.hasPrefix("message_") || kind.hasPrefix("tool_execution_")
                || kind.hasPrefix("auto_compaction_") || kind.hasPrefix("auto_retry_")
                || kind == "model_changed" || kind == "thinking_level_changed" {
                await onEvent(value)
            } else {
                await onEvent(value)
            }
        case nil:
            break
        }
    }

    private func reassemble(_ value: JSONValue) {
        guard let chunkID = value["chunkId"]?.stringValue,
            let index = value["index"]?.intValue,
            let count = value["count"]?.intValue,
            let byteLength = value["byteLength"]?.intValue,
            case .string(let encoded)? = value["data"],
            let segment = Data(base64Encoded: encoded)
        else { return }
        var state = chunks[chunkID] ?? (count, [:], 0)
        guard state.count == count, state.parts[index] == nil else {
            chunks.removeValue(forKey: chunkID)
            return
        }
        state.parts[index] = segment
        state.bytes += segment.count
        guard state.bytes <= reassemblyLimit, byteLength <= reassemblyLimit else {
            chunks.removeValue(forKey: chunkID)
            return
        }
        if state.parts.count == count {
            chunks.removeValue(forKey: chunkID)
            var whole = Data()
            whole.reserveCapacity(byteLength)
            for i in 0..<count {
                guard let part = state.parts[i] else { return }
                whole.append(part)
            }
            guard whole.count == byteLength,
                let text = String(data: whole, encoding: .utf8),
                let data = text.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data)
            else { return }
            let parsed = JSONValue.from(obj)
            Task { await self.handleLine(parsed) }
        } else {
            chunks[chunkID] = state
        }
    }

    private func sendRaw(_ object: [String: Any]) -> Bool {
        guard let handle = stdinHandle,
            let data = try? JSONSerialization.data(withJSONObject: object),
            let line = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8)
        else { return false }
        do {
            try handle.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    func sendExternal(_ object: [String: Any]) async -> Bool {
        sendRaw(object)
    }

    func request(
        _ type: String, fields: [String: Any] = [:], timeout: TimeInterval = 30
    ) async -> OmpRPCResponse {
        nextRequestID += 1
        let id = "req-\(nextRequestID)"
        var object: [String: Any] = ["id": id, "type": type]
        for (key, value) in fields { object[key] = value }
        guard isRunning, sendRaw(object) else {
            return OmpRPCResponse(
                command: type, success: false, error: "The oh-my-pi process is not running",
                errorCode: nil, data: nil)
        }
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<OmpRPCResponse, Never>) in
            pending[id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let timedOut = self.pending.removeValue(forKey: id) {
                    timedOut.resume(
                        returning: OmpRPCResponse(
                            command: type, success: false, error: "Timed out", errorCode: "timeout",
                            data: nil))
                }
            }
        }
        return response
    }
}

final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var searchFrom = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() -> String? {
        while true {
            if let idx = buffer[searchFrom...].firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[0..<idx], as: UTF8.self)
                buffer.removeFirst(idx + 1)
                searchFrom = 0
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            searchFrom = max(0, buffer.count - 1)
            let chunk = handle.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer = []
                searchFrom = 0
                return line
            }
            buffer.append(contentsOf: chunk)
        }
    }
}
