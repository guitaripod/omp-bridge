import Foundation

struct OmpRPCResponse: Sendable {
    let command: String
    let success: Bool
    let error: String?
    let errorCode: String?
    let data: JSONValue?
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
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
        case is NSNull:
            return .null
        case let n as NSNumber:
            let objCType = String(cString: n.objCType)
            if objCType == "c" { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map { from($0) })
        case let o as [String: Any]:
            return .object(o.mapValues { from($0) })
        default:
            return .string(String(describing: any))
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
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var chunks: [String: (count: Int, parts: [Int: Data], bytes: Int)] = [:]
    private var reassemblyLimit = 67_108_864
    private(set) var protocolVersion = 1
    private(set) var isRunning = false
    private var negotiated = false
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
    /// `omp` is a `#!/usr/bin/env bun` script, and a service started at boot carries a PATH
    /// without `~/.bun/bin`, so the binary's own directory goes in front of whatever PATH the
    /// bridge inherited or the process cannot start at all.
    private static func pathReachingRuntime(of binary: String, base: String?) -> String {
        let dir = (binary as NSString).deletingLastPathComponent
        var parts = (base ?? "/usr/local/bin:/usr/bin").split(separator: ":").map(String.init)
        parts.removeAll { $0 == dir }
        parts.insert(dir, at: 0)
        return parts.joined(separator: ":")
    }

    func start() async throws {
        guard !isRunning else { return }
        negotiated = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ompBin)
        p.arguments = ["--mode", "rpc"]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        env.merge(extraEnv) { _, new in new }
        env["PATH"] = Self.pathReachingRuntime(of: ompBin, base: env["PATH"])
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
        let channel = self
        Task.detached(priority: .userInitiated) { [weak channel] in
            while let line = reader.nextLine() {
                guard !line.isEmpty, let data = line.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: data)
                else { continue }
                await channel?.ingest(JSONValue.from(obj))
            }
            await channel?.terminated()
        }
        let deadline = Date().addingTimeInterval(10)
        while !negotiated, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    var processID: Int? {
        process.map { Int($0.processIdentifier) }
    }

    private func terminated() {
        guard isRunning else { return }
        isRunning = false
        negotiated = true
        let waiters = pending
        pending.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(
                returning: OmpRPCResponse(
                    command: "process", success: false,
                    error: "The oh-my-pi process exited", errorCode: nil, data: nil))
        }
    }

    func stop() async {
        guard let process, isRunning else { return }
        try? stdinHandle?.close()
        stdinHandle = nil
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
        isRunning = false
    }

    func ingest(_ value: JSONValue) async {
        await handleLine(value)
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
            negotiated = true
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
                timeouts.removeValue(forKey: id)?.cancel()
                continuation.resume(returning: response)
            }
        case .some:
            await onEvent(value)
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
            timeouts[id] = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                if let timedOut = self.pending.removeValue(forKey: id) {
                    self.timeouts.removeValue(forKey: id)
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
