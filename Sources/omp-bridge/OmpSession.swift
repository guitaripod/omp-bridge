import Foundation

struct QueuedPrompt: Codable, Sendable {
    var prompt: String
    var displayPrompt: String
    var model: String?
    var effort: String?
}

struct TurnRecord: Codable, Sendable {
    var at: Date
    var seconds: Double?
    var model: String?
    var calls: Int
    var tokens: TokenCounts
    var costUSD: Double
    var prompt: String?
}

struct SubagentState: Sendable {
    var id: String
    var title: String?
    var active: Bool
    var updatedAt: Date
    var lastNote: String?
}

enum LivePart {
    case text(String)
    case reasoning(String)
    case tool(ToolCall)
    case file(FileRef)
}

private func mergeIntoObject(_ value: JSONValue, key: String, value addition: JSONValue) -> JSONValue {
    var dict = value.objectValue ?? [:]
    dict[key] = addition
    return .object(dict)
}

actor OmpSession {
    let id: String
    private(set) var title: String
    private(set) var directory: String
    private(set) var model: String
    private(set) var effort: String
    private(set) var ompSessionID: String?
    private(set) var ompSessionFile: String?
    private(set) var createdAt: Date
    private(set) var updatedAt: Date
    private(set) var messages: [Message] = []
    private(set) var customTitle = false
    private(set) var autoTitled = false

    private let config: Config
    private let hub: Hub
    private let quietRegistry: QuietRegistry
    private var process: OmpProcess?
    private(set) var running = false
    private(set) var compacting = false
    private var queued: [QueuedPrompt] = []
    private var turns: [TurnRecord] = []
    private(set) var totalCostUSD = 0.0
    private(set) var totalTokens = TokenCounts()

    private var liveMessageID: String?
    private var liveCreatedAt: Date?
    private var liveParts: [LivePart] = []
    private var liveUsage = TokenCounts()
    private var liveCost = 0.0
    private var liveModel: String?
    private var turnStartedAt: Date?
    private var turnPrompt: String?
    private var turnCalls = 0
    private var turnTokens = TokenCounts()
    private var turnCost = 0.0
    private var turnHadContent = false
    private var turnLastErrorMessage: String?
    private var pendingUI: PendingUI?
    private var subagents: [String: SubagentState] = [:]
    private var knownCommands: [AgentCommandDTO] = []

    struct PendingUI: Sendable {
        let requestID: String
        let method: String
        let title: String?
        let message: String?
        let options: [String]
        let toolCallID: String
        let questionJSON: String
        let askedAt: Date
    }

    var summary: SessionSummary {
        SessionSummary(
            id: id, title: title, directory: directory, model: model, effort: effort,
            createdAt: createdAt, updatedAt: updatedAt,
            active: running ? true : nil,
            interrupted: nil,
            agents: activeAgentCount > 0 ? activeAgentCount : nil)
    }

    private var activeAgentCount: Int {
        subagents.values.filter(\.active).count
    }

    init(
        id: String = UUID().uuidString, title: String = "New chat", directory: String,
        model: String, effort: String, ompSessionFile: String? = nil, config: Config, hub: Hub,
        quietRegistry: QuietRegistry
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.model = model
        self.effort = effort
        self.ompSessionFile = ompSessionFile
        self.createdAt = Date()
        self.updatedAt = Date()
        self.config = config
        self.hub = hub
        self.quietRegistry = quietRegistry
    }

    func snapshotMessages() -> [Message] { messages }
    func snapshotTurns() -> [TurnRecord] { turns }
    func spendTotals() -> (costUSD: Double, tokens: TokenCounts) { (totalCostUSD, totalTokens) }
    func lastTurnCost() -> (costUSD: Double, tokens: Int)? {
        guard let turn = turns.last else { return nil }
        return (turn.costUSD, turn.tokens.total)
    }

    func rename(_ newTitle: String) {
        title = newTitle
        customTitle = true
        touch()
    }

    func setAutoResume(_ enabled: Bool) {}

    func subagentSummaries() -> [SubagentSummary] {
        subagents.values.map { state in
            SubagentSummary(
                id: state.id, title: state.title ?? "agent", agentType: nil, toolUseID: nil,
                updatedAt: state.updatedAt, active: state.active, completed: !state.active,
                startedAt: nil, toolCount: nil, currentTool: state.lastNote)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func subagentTranscript(agentID: String) -> SubagentTranscript? {
        nil
    }

    func commandCatalog() -> [AgentCommandDTO] {
        knownCommands
    }

    private func touch() {
        updatedAt = Date()
    }

    // MARK: process lifecycle

    func ensureProcess() async throws -> OmpProcess {
        if let existing = process, await existing.isRunning { return existing }
        let proc = OmpProcess(
            ompBin: config.ompBin, directory: directory,
            extraEnv: ["PI_RPC_EMIT_TITLE": "0"]
        ) { [weak self] frame in
            await self?.handleOmpEvent(frame)
        }
        try await proc.start()
        process = proc
        if let file = ompSessionFile {
            _ = await proc.request("switch_session", fields: ["sessionPath": file], timeout: 60)
            adoptTranscriptIfNeeded()
        }
        if !model.isEmpty {
            let target = model
            Task { await self.applyModelOn(proc, target) }
        }
        Task { await proc.request("set_subagent_subscription", fields: ["level": "events"]) }
        return proc
    }

    private func applyModelOn(_ proc: OmpProcess, _ target: String) async {
        let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            _ = await proc.request(
                "set_model", fields: ["provider": parts[0], "modelId": parts[1]])
        } else if let models = await proc.request("get_available_models").data,
            let list = models["models"]?.arrayValue
        {
            for entry in list {
                if entry["id"]?.stringValue == target || entry["name"]?.stringValue == target {
                    if let provider = entry["provider"]?.stringValue, let modelID = entry["id"]?.stringValue {
                        _ = await proc.request(
                            "set_model", fields: ["provider": provider, "modelId": modelID])
                    }
                    break
                }
            }
        }
    }

    func shutdown() async {
        await process?.stop()
        process = nil
    }

    // MARK: sending

    func send(
        text rawText: String, displayText shown: String? = nil, model wantModel: String?,
        effort wantEffort: String?, attachments files: [FileRef] = []
    ) async throws -> (queued: Bool, position: Int?)
    {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BridgeError.badRequest("Empty message") }

        if text.hasPrefix("/compact") {
            let instructions =
                text.dropFirst("/compact".count).trimmingCharacters(in: .whitespacesAndNewlines)
            try await startCompaction(instructions: instructions.isEmpty ? nil : instructions)
            return (false, nil)
        }

        if pendingUI != nil {
            await resolvePendingUI(with: shown ?? text)
            return (false, nil)
        }

        var promptText = text
        if let wantEffort, wantEffort != effort {
            effort = normalizeEffort(wantEffort)
            if let process {
                _ = await process.request(
                    "set_thinking_level", fields: ["level": thinkingLevel(for: effort)])
            }
        }
        if let wantModel, wantModel != model {
            model = wantModel
            if let process {
                await applyModelOn(process, wantModel)
            }
        }

        var userParts: [Part] = [.text(shown ?? text)]
        userParts.append(contentsOf: files.map { Part.file($0) })
        let userMessage = Message(
            id: "u-\(UUID().uuidString.prefix(8))", role: .user,
            parts: userParts, createdAt: Date(), seconds: nil, model: nil, usage: nil,
            costUSD: nil)
        messages.append(userMessage)
        touch()
        await publish(.messageUpserted(userMessage))

        if running {
            let position = queued.count
            queued.append(QueuedPrompt(prompt: promptText, displayPrompt: shown ?? text, model: wantModel, effort: wantEffort))
            return (true, position)
        }
        try await startTurn(prompt: promptText, display: shown ?? text)
        return (false, nil)
    }

    private func startTurn(prompt: String, display: String) async throws {
        let proc = try await ensureProcess()
        running = true
        turnStartedAt = Date()
        turnPrompt = display
        turnCalls = 0
        turnTokens = TokenCounts()
        turnCost = 0
        turnHadContent = false
        turnLastErrorMessage = nil
        await quietRegistry.increment()
        await publish(.status("running"))
        _ = await proc.request("prompt", fields: ["message": prompt])
        let state = await proc.request("get_state", timeout: 15)
        if let data = state.data {
            if let file = data["sessionFile"]?.stringValue { ompSessionFile = file }
            if let sid = data["sessionId"]?.stringValue { ompSessionID = sid }
        }
    }

    func abort() async -> Bool {
        guard running, let process else { return false }
        _ = await process.request("abort")
        queued.removeAll()
        finishTurn()
        return true
    }

    func clear() throws {
        guard !running, queued.isEmpty else {
            throw BridgeError.conflict("A turn is running or queued")
        }
        messages.removeAll()
        turns.removeAll()
        totalCostUSD = 0
        totalTokens = TokenCounts()
        touch()
    }

    func startCompaction(instructions: String?) async throws {
        guard !compacting else {
            throw BridgeError.conflict("A compaction is already running")
        }
        let proc = try await ensureProcess()
        compacting = true
        await publish(.compaction(phase: "started", error: nil))
        var fields: [String: Any] = [:]
        if let instructions, !instructions.isEmpty { fields["customInstructions"] = instructions }
        let response = await proc.request("compact", fields: fields, timeout: 900)
        compacting = false
        if response.success {
            await publish(.compaction(phase: "finished", error: nil))
        } else {
            await publish(.compaction(phase: "failed", error: response.error))
        }
    }

    private func drainQueue() async {
        guard !running, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        let userMessage = Message(
            id: "u-\(UUID().uuidString.prefix(8))", role: .user,
            parts: [.text(next.displayPrompt)], createdAt: Date(), seconds: nil, model: nil,
            usage: nil, costUSD: nil)
        messages.append(userMessage)
        touch()
        await publish(.messageUpserted(userMessage))
        do {
            try await startTurn(prompt: next.prompt, display: next.displayPrompt)
        } catch {
            await publish(.error(error.localizedDescription))
        }
    }

    private func finishTurn() {
        guard running else { return }
        running = false
        if let startedAt = turnStartedAt {
            let record = TurnRecord(
                at: startedAt, seconds: Date().timeIntervalSince(startedAt), model: liveModel,
                calls: max(turnCalls, 1), tokens: turnTokens, costUSD: turnCost,
                prompt: turnPrompt)
            turns.append(record)
            if turns.count > 400 { turns.removeFirst(turns.count - 400) }
        }
        totalCostUSD += turnCost
        totalTokens = totalTokens + turnTokens
        turnStartedAt = nil
        settleUnansweredAsk()
        Task {
            await publish(.status("idle"))
            await quietRegistry.decrement()
            await drainQueue()
        }
    }

    private func settleUnansweredAsk() {
        guard let ui = pendingUI else { return }
        if let index = indexOfToolPart(ui.toolCallID) {
            updateToolPart(index: index) { tool in
                tool.status = .error
                tool.output = "Unanswered"
            }
            if let messageID = liveMessageID ?? messages.last?.id {
                let call = extractTool(at: index)
                Task { await publishTool(call, messageID: messageID) }
            }
        }
        pendingUI = nil
    }

    // MARK: extension UI (asks)

    private func handleUIRequest(_ frame: JSONValue) async {
        guard let requestID = frame["id"]?.stringValue else { return }
        let method = frame["method"]?.stringValue ?? ""
        switch method {
        case "select", "confirm", "input":
            let options = (frame["options"]?.arrayValue ?? []).compactMap(\.stringValue)
            let optionDetails = frame["optionDetails"]?.arrayValue
            var descriptions: [String] = []
            if let details = optionDetails {
                descriptions = details.compactMap { $0["description"]?.stringValue ?? "" }
            }
            let questionText = frame["message"]?.stringValue ?? frame["title"]?.stringValue ?? "Question"
            var questions: [JSONValue] = [
                .object([
                    "question": .string(questionText),
                    "header": .string(frame["title"]?.stringValue ?? ""),
                    "multiSelect": .bool(false),
                ])
            ]
            if method == "select", !options.isEmpty {
                let optionValues = options.enumerated().map { offset, label in
                    var option: [String: JSONValue] = ["label": .string(label)]
                    if offset < descriptions.count, !descriptions[offset].isEmpty {
                        option["description"] = .string(descriptions[offset])
                    }
                    return JSONValue.object(option)
                }
                questions[0] = mergeIntoObject(questions[0], key: "options", value: .array(optionValues))
            } else if method == "confirm" {
                questions[0] = mergeIntoObject(
                    questions[0], key: "options",
                    value: .array([
                        .object(["label": .string("Yes"), "description": .string("")]),
                        .object(["label": .string("No"), "description": .string("")]),
                    ]))
            }
            guard let payloadData = try? JSONSerialization.data(
                withJSONObject: ["questions": questions.map(\.raw)]),
                let json = String(data: payloadData, encoding: .utf8)
            else { return }
            let toolCallID = "ask-\(requestID)"
            let call = ToolCall(
                id: toolCallID, name: "AskUserQuestion", input: json, output: nil,
                status: .running)
            liveParts.append(.tool(call))
            pendingUI = PendingUI(
                requestID: requestID, method: method, title: frame["title"]?.stringValue,
                message: questionText, options: options, toolCallID: toolCallID,
                questionJSON: json, askedAt: Date())
            if let messageID = liveMessageID {
                await publishTool(call, messageID: messageID)
            }
        default:
            break
        }
    }

    private func resolvePendingUI(with text: String) async {
        guard let ui = pendingUI else { return }
        pendingUI = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = ["id": ui.requestID, "type": "extension_ui_response"]
        switch ui.method {
        case "confirm":
            let lowered = loweredFirstWord(trimmed)
            payload["confirmed"] = ["yes", "y", "ok", "sure", "do it", "go ahead"].contains(lowered)
        case "select":
            var chosen: String?
            if let index = Int(trimmed), ui.options.indices.contains(index) {
                chosen = ui.options[index]
            }
            if chosen == nil {
                chosen = ui.options.first {
                    $0.caseInsensitiveCompare(trimmed) == .orderedSame
                }
            }
            if chosen == nil {
                chosen = ui.options.first {
                    loweredFirstWord($0) == loweredFirstWord(trimmed)
                }
            }
            payload["value"] = chosen ?? trimmed
        default:
            payload["value"] = trimmed
        }
        let answerLabel =
            (payload["value"] as? String)
            ?? ((payload["confirmed"] as? Bool).map { $0 ? "Yes" : "No" }) ?? trimmed
        if let index = indexOfToolPart(ui.toolCallID) {
            updateToolPart(index: index) { tool in
                tool.status = .completed
                tool.output = "Your questions have been answered: \"\(ui.message ?? "")\"=\"\(answerLabel)\"."
            }
            if let messageID = liveMessageID {
                let call = extractTool(at: index)
                await publishTool(call, messageID: messageID)
            }
        }
        if let process {
            _ = await process.sendExternal(payload)
        }
    }

    private func loweredFirstWord(_ s: String) -> String {
        s.lowercased().split(separator: " ").first.map(String.init) ?? s.lowercased()
    }

    // MARK: omp event mapping

    private func handleOmpEvent(_ frame: JSONValue) async {
        let type = frame["type"]?.stringValue ?? ""
        switch type {
        case "agent_start":
            running = true
            if turnStartedAt == nil { turnStartedAt = Date() }
        case "turn_start":
            turnCalls += 1
        case "message_start":
            await handleMessageStart(frame)
        case "message_update":
            await handleMessageUpdate(frame)
        case "message_end":
            await handleMessageEnd(frame)
        case "tool_execution_start":
            await handleExecutionStart(frame)
        case "tool_execution_update":
            await handleExecutionUpdate(frame)
        case "tool_execution_end":
            await handleExecutionEnd(frame)
        case "auto_compaction_start":
            if frame["skipped"]?.boolValue != true {
                compacting = true
                await publish(.compaction(phase: "started", error: nil))
            }
        case "auto_compaction_end":
            if frame["skipped"]?.boolValue == true { break }
            compacting = false
            let failed = frame["aborted"]?.boolValue == true
            await publish(
                .compaction(phase: failed ? "failed" : "finished",
                            error: failed ? "Aborted" : nil))
        case "extension_ui_request":
            await handleUIRequest(frame)
        case "notice":
            break
        case "available_commands_update":
            knownCommands = Self.parseCommands(frame["commands"]?.arrayValue ?? [])
        case "subagent_lifecycle", "subagent_progress", "subagent_event":
            recordSubagentFrame(frame, type: type)
        case "agent_end":
            let terminal = frame["isTerminal"]?.boolValue ?? true
            if terminal {
                await settleTurnEnd()
            }
        default:
            break
        }
    }

    private static func parseCommands(_ list: [JSONValue]) -> [AgentCommandDTO] {
        list.compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return AgentCommandDTO(
                name: name, description: entry["description"]?.stringValue,
                argumentHint: entry["input"]?["hint"]?.stringValue, source: "builtin",
                scope: nil)
        }
    }

    private func recordSubagentFrame(_ frame: JSONValue, type: String) {
        guard let agentID = frame["subagentId"]?.stringValue ?? frame["id"]?.stringValue else { return }
        var state = subagents[agentID] ?? SubagentState(id: agentID, title: nil, active: true, updatedAt: Date(), lastNote: nil)
        if let description = frame["description"]?.stringValue ?? frame["task"]?.stringValue {
            state.title = description
        }
        if type == "subagent_progress", let note = frame["note"]?.stringValue ?? frame["status"]?.stringValue {
            state.lastNote = note
        }
        if type == "subagent_lifecycle" {
            let phase = frame["phase"]?.stringValue ?? frame["status"]?.stringValue ?? ""
            if ["completed", "failed", "cancelled", "done", "stopped"].contains(phase) {
                state.active = false
            }
        }
        state.updatedAt = Date()
        subagents[agentID] = state
    }

    private func handleMessageStart(_ frame: JSONValue) async {
        guard let message = frame["message"], let role = message["role"]?.stringValue else { return }
        switch role {
        case "assistant":
            liveMessageID = "a-\(UUID().uuidString.prefix(8))"
            liveCreatedAt = Date()
            liveParts = []
            liveUsage = TokenCounts()
            liveCost = 0
            liveModel = message["model"]?.stringValue ?? liveModel
        case "user", "toolResult":
            break
        default:
            break
        }
    }

    private func handleMessageUpdate(_ frame: JSONValue) async {
        guard let event = frame["assistantMessageEvent"], let kind = event["type"]?.stringValue,
            let messageID = liveMessageID
        else { return }
        switch kind {
        case "text_start":
            liveParts.append(.text(""))
        case "text_delta":
            let delta = event["delta"]?.stringValue ?? ""
            appendToLiveText(delta)
            turnHadContent = true
            await publish(.partTextDelta(messageID: messageID, delta: delta))
        case "text_end":
            break
        case "thinking_start":
            liveParts.append(.reasoning(""))
        case "thinking_delta":
            let delta = event["delta"]?.stringValue ?? ""
            appendToLiveReasoning(delta)
            await publish(.partTextDelta(messageID: messageID, delta: delta))
        case "toolcall_start":
            liveParts.append(
                .tool(ToolCall(id: "pending-\(liveParts.count)", name: "", input: "", status: .running)))
        case "toolcall_delta":
            let delta = event["delta"]?.stringValue ?? ""
            if let index = lastLiveToolIndex() {
                updateToolPart(index: index) { $0.input += delta }
            }
        case "toolcall_end":
            if let call = event["toolCall"], let index = lastLiveToolIndex() {
                let arguments = Self.serializeArguments(call["arguments"])
                updateToolPart(index: index) { tool in
                    tool.id = call["id"]?.stringValue ?? tool.id
                    tool.name = call["name"]?.stringValue ?? tool.name
                    tool.input = arguments
                }
            }
        default:
            break
        }
    }

    static func serializeArguments(_ value: JSONValue?) -> String {
        guard let value else { return "{}" }
        if case .object(let dict) = value {
            let plain = dict.mapValues(\.raw)
            if let data = try? JSONSerialization.data(withJSONObject: plain),
                let text = String(data: data, encoding: .utf8)
            { return text }
        }
        return "{}"
    }

    private func appendToLiveText(_ delta: String) {
        for index in stride(from: liveParts.count - 1, through: 0, by: -1) {
            if case .text(let existing) = liveParts[index] {
                liveParts[index] = .text(existing + delta)
                return
            }
        }
        liveParts.append(.text(delta))
    }

    private func appendToLiveReasoning(_ delta: String) {
        for index in stride(from: liveParts.count - 1, through: 0, by: -1) {
            if case .reasoning(let existing) = liveParts[index] {
                liveParts[index] = .reasoning(existing + delta)
                return
            }
        }
        liveParts.append(.reasoning(delta))
    }

    private func lastLiveToolIndex() -> Int? {
        liveParts.lastIndex { if case .tool = $0 { return true }; return false }
    }

    private func indexOfToolPart(_ toolID: String) -> Int? {
        liveParts.lastIndex {
            if case .tool(let call) = $0 { return call.id == toolID }
            return false
        } ?? messages.last?.parts.lastIndex(where: { part in
            if case .tool(let call) = part { return call.id == toolID }
            return false
        })
    }

    private func updateToolPart(index: Int, _ mutate: (inout ToolCall) -> Void) {
        if liveParts.indices.contains(index), case .tool(var call) = liveParts[index] {
            mutate(&call)
            liveParts[index] = .tool(call)
        }
    }

    private func extractTool(at index: Int) -> ToolCall {
        if liveParts.indices.contains(index), case .tool(let call) = liveParts[index] {
            return call
        }
        if let part = messages.last?.parts[safe: index], case .tool(let call) = part {
            return call
        }
        return ToolCall(id: "unknown", name: "", input: "", status: .error)
    }

    private func handleMessageEnd(_ frame: JSONValue) async {
        guard let message = frame["message"], let role = message["role"]?.stringValue else { return }
        switch role {
        case "assistant":
            finalizeAssistant(message)
            if let id = liveMessageID, let created = liveCreatedAt {
                let assembled = Message(
                    id: id, role: .assistant, parts: materializedParts(),
                    createdAt: created,
                    seconds: turnStartedAt.map { Date().timeIntervalSince($0) },
                    model: liveModel, usage: liveUsage, costUSD: liveCost)
                messages.append(assembled)
                touch()
                await publish(.messageUpserted(assembled))
                liveMessageID = nil
                liveParts = []
            }
            if let errorMessage = message["errorMessage"]?.stringValue,
                message["stopReason"]?.stringValue == "error"
            {
                turnLastErrorMessage = errorMessage
            }
        default:
            break
        }
    }

    private func finalizeAssistant(_ message: JSONValue) {
        let usage = message["usage"]
        let input = usage?["input"]?.intValue ?? 0
        let output = usage?["output"]?.intValue ?? 0
        let cacheRead = usage?["cacheRead"]?.intValue ?? 0
        let cacheWrite = usage?["cacheWrite"]?.intValue ?? 0
        let counts = TokenCounts(
            input: input, output: output, cacheRead: cacheRead, cacheWrite5m: cacheWrite,
            cacheWrite1h: 0)
        liveUsage = liveUsage + counts
        turnTokens = turnTokens + counts
        let cost = usage?["cost"]?["total"]?.doubleValue ?? 0
        liveCost += cost
        turnCost += cost
        if let model = message["model"]?.stringValue { liveModel = model }
    }

    private func materializedParts() -> [Part] {
        liveParts.map { part in
            switch part {
            case .text(let text): .text(text)
            case .reasoning(let text): .reasoning(text)
            case .tool(let call): .tool(call)
            case .file(let ref): .file(ref)
            }
        }
    }

    private func handleExecutionStart(_ frame: JSONValue) async {
        guard let toolCallID = frame["toolCallId"]?.stringValue else { return }
        let name = frame["toolName"]?.stringValue ?? ""
        let args = Self.serializeArguments(frame["args"])
        if let index = indexOfToolPart(toolCallID) {
            updateToolPart(index: index) { tool in
                tool.id = toolCallID
                tool.name = name
                if tool.input.isEmpty { tool.input = args }
                tool.status = .running
            }
            await publishTool(at: index)
        }
    }

    private func handleExecutionUpdate(_ frame: JSONValue) async {
        guard let toolCallID = frame["toolCallId"]?.stringValue else { return }
        let texts = (frame["partialResult"]?["content"]?.arrayValue ?? []).compactMap {
            $0["text"]?.stringValue
        }
        let output = texts.joined()
        if let index = indexOfToolPart(toolCallID) {
            updateToolPart(index: index) { tool in
                tool.output = String(output.prefix(10_000))
            }
            await publishTool(at: index)
        }
    }

    private func handleExecutionEnd(_ frame: JSONValue) async {
        guard let toolCallID = frame["toolCallId"]?.stringValue else { return }
        let isError = frame["isError"]?.boolValue ?? false
        var output = (frame["result"]?["content"]?.arrayValue ?? [])
            .compactMap { $0["text"]?.stringValue }.joined()
        if output.isEmpty {
            output = (frame["result"]?["content"]?.arrayValue ?? []).compactMap {
                $0["image"]?.stringValue
            }.joined()
        }
        if let index = indexOfToolPart(toolCallID) {
            updateToolPart(index: index) { tool in
                tool.status = isError ? .error : .completed
                tool.output = String(output.prefix(10_000))
            }
            await attachResultFiles(frame, toolCallID: toolCallID)
        }
    }

    private func attachResultFiles(_ frame: JSONValue, toolCallID: String) async {
        guard let contents = frame["result"]?["content"]?.arrayValue else { return }
        for content in contents {
            guard let path = content["path"]?.stringValue ?? content["filePath"]?.stringValue,
                isImagePath(path)
            else { continue }
            let filename = (path as NSString).lastPathComponent
            let mime = mimeForExtension(filename)
            let url =
                "/files/raw?path=\(Self.percentEncode(path))&tool=\(Self.percentEncode(toolCallID))&session=\(Self.percentEncode(ompSessionID ?? id))"
            let fileRef = FileRef(path: path, mime: mime, filename: filename, url: url)
            if let index = liveParts.lastIndex(where: {
                if case .tool(let call) = $0 { return call.id == toolCallID }
                return false
            }) {
                liveParts.insert(.file(fileRef), at: min(index + 1, liveParts.count))
            } else {
                liveParts.append(.file(fileRef))
            }
        }
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(
            (path as NSString).pathExtension.lowercased())
    }

    private func mimeForExtension(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }

    private func publishTool(at index: Int) async {
        guard let messageID = liveMessageID,
            liveParts.indices.contains(index),
            case .tool(let call) = liveParts[index]
        else { return }
        await publish(.toolUpserted(messageID: messageID, call))
    }

    private func publishTool(_ call: ToolCall, messageID: String) async {
        await publish(.toolUpserted(messageID: messageID, call))
    }

    private func settleTurnEnd() async {
        if !turnHadContent, let error = turnLastErrorMessage {
            await publish(.error(error))
        }
        finishTurn()
    }

    // MARK: helpers

    private func publish(_ event: BridgeEvent) async {
        await hub.publish(.session(id: id, event: event))
    }

    func normalizeEffort(_ value: String) -> String {
        switch value.lowercased() {
        case "low", "minimal": "low"
        case "high", "max", "xhigh": "high"
        default: "medium"
        }
    }

    func thinkingLevel(for effort: String) -> String {
        switch effort {
        case "low": "low"
        case "high": "high"
        default: "medium"
        }
    }

    private func adoptTranscriptIfNeeded() {
        guard messages.isEmpty, let file = ompSessionFile else { return }
        let loaded = TranscriptLoader.load(sessionFile: file)
        if !loaded.messages.isEmpty {
            messages = loaded.messages
            ompSessionID = loaded.sessionID
            if let first = loaded.firstUserText, !customTitle {
                title = Self.derivedTitle(from: first)
                autoTitled = true
            }
        }
    }

    static func derivedTitle(from text: String) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 48 { return trimmed.isEmpty ? "New chat" : trimmed }
        return String(trimmed.prefix(48))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension OmpSession {
    func titleText() -> String { title }
    func directoryPath() -> String { directory }
    func modelName() -> String { model }
    func effortLevel() -> String { effort }
    func createdDate() -> Date { createdAt }
    func updatedDate() -> Date { updatedAt }
    func currentOmpSessionID() -> String? { ompSessionID }

    func ownedTranscriptIDs() -> [String] {
        var ids: Set<String> = [id]
        if let ompSessionID { ids.insert(ompSessionID) }
        return ids.sorted()
    }

    func customTitleValue() -> Bool { customTitle }
    func autoTitledValue() -> Bool { autoTitled }
    func turnsSnapshot() -> [TurnRecord] { turns }
    func spendTotalsSnapshot() -> (costUSD: Double, tokens: TokenCounts) {
        (totalCostUSD, totalTokens)
    }
    func isRunningValue() -> Bool { running }
    func pendingInterruption() -> Interruption? { nil }

    func summarySnapshot() -> SessionSummary { summary }

    func adoptExternally(loaded: LoadedTranscript, ompID: String?) async {
        messages = loaded.messages
        if let id = ompID ?? loaded.sessionID { ompSessionID = id }
        if let cwd = loaded.cwd { directory = cwd }
        if let first = loaded.firstUserText, !customTitle {
            title = Self.derivedTitle(from: first)
            autoTitled = true
        }
    }

    func sessionFile() -> String? { ompSessionFile }
}
