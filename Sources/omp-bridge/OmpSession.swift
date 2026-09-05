import Foundation

struct QueuedPrompt: Codable, Sendable {
    var prompt: String
    var displayPrompt: String
    var model: String?
    var effort: String?
    var compaction: Bool?
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
    private let journal: TurnJournal?
    private var process: OmpProcess?
    private(set) var running = false
    private(set) var externallyLive = false
    private(set) var compacting = false
    private var compactionStartedAt: Date?
    private var lastEventAt = Date.distantPast
    private var queued: [QueuedPrompt] = []
    private var turns: [TurnRecord] = []
    private(set) var totalCostUSD = 0.0
    private(set) var totalTokens = TokenCounts()

    private var liveMessageID: String?
    private var liveCreatedAt: Date?
    private var liveParts: [LivePart] = []
    private var liveUsage = TokenCounts()
    private var liveContext: TokenCounts?
    private var liveCost = 0.0
    private var liveModel: String?
    private var lastSnapshotAt = Date.distantPast
    private var lastTranscriptMtime: Date?
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
            active: (running || externallyLive) ? true : nil,
            interrupted: nil,
            agents: activeAgentCount > 0 ? activeAgentCount : nil)
    }

    private var activeAgentCount: Int {
        subagents.values.filter(\.active).count
    }

    init(
        id: String = UUID().uuidString, title: String = "New chat", directory: String,
        model: String, effort: String, ompSessionFile: String? = nil, config: Config, hub: Hub,
        quietRegistry: QuietRegistry, journal: TurnJournal? = nil,
        restoredDates: (createdAt: Date, updatedAt: Date)? = nil
    ) {
        self.id = id
        self.title = title
        self.directory = directory
        self.model = model
        self.effort = effort
        self.ompSessionFile = ompSessionFile
        self.createdAt = restoredDates?.createdAt ?? Date()
        self.updatedAt = restoredDates?.updatedAt ?? Date()
        self.config = config
        self.hub = hub
        self.quietRegistry = quietRegistry
        self.journal = journal
    }

    func snapshotMessages() -> [Message] {
        guard let live = liveMessageSnapshot() else { return messages }
        return messages + [live]
    }
    func snapshotTurns() -> [TurnRecord] { turns }
    func spendTotals() -> (costUSD: Double, tokens: TokenCounts) { (totalCostUSD, totalTokens) }
    func lastTurnCost() -> (costUSD: Double, tokens: Int)? {
        guard let turn = turns.last else { return nil }
        return (turn.costUSD, turn.tokens.total)
    }

    /// A conversation names itself after the first thing said in it. A session the bridge started
    /// used to keep its placeholder forever — only a transcript adopted from disk derived a title —
    /// so every chat opened from a client listed as a new one however long it had run.
    private func titleFromFirstPrompt(_ text: String) {
        guard !customTitle, !autoTitled, Self.isPlaceholderTitle(title) else { return }
        let derived = Self.derivedTitle(from: text)
        guard derived != "New chat" else { return }
        title = derived
        autoTitled = true
    }

    static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "New chat" || trimmed.hasPrefix("New session")
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
            await applyModelOn(proc, model)
        }
        if !effort.isEmpty {
            _ = await proc.request("set_thinking_level", fields: ["level": effort])
        }
        Task { await proc.request("set_subagent_subscription", fields: ["level": "events"]) }
        return proc
    }

    /// Pins the engine to `target` (`provider/modelId`, or a bare id resolved against the live
    /// catalog) and says whether the engine accepted it, so a caller can refuse to spend a turn
    /// on whatever default the pin would have silently fallen through to.
    @discardableResult
    private func applyModelOn(_ proc: OmpProcess, _ target: String) async -> Bool {
        let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let response = await proc.request(
                "set_model", fields: ["provider": parts[0], "modelId": parts[1]])
            if response.success { return true }
        }
        guard let models = await proc.request("get_available_models", timeout: 120).data,
            let list = models["models"]?.arrayValue
        else { return false }
        let wanted = parts.count == 2 ? parts[1] : target
        for entry in list {
            guard entry["id"]?.stringValue == wanted || entry["name"]?.stringValue == wanted,
                parts.count != 2 || entry["provider"]?.stringValue == parts[0],
                let provider = entry["provider"]?.stringValue,
                let modelID = entry["id"]?.stringValue
            else { continue }
            let response = await proc.request(
                "set_model", fields: ["provider": provider, "modelId": modelID])
            return response.success
        }
        return false
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
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BridgeError.badRequest("Empty message") }

        if running { await healDeadTurn() }

        if text.hasPrefix("/compact") {
            let instructions =
                text.dropFirst("/compact".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !compacting else {
                throw BridgeError.conflict("A compaction is already running")
            }
            if running || !queued.isEmpty {
                let position = queued.count
                queued.append(
                    QueuedPrompt(
                        prompt: instructions, displayPrompt: text, model: nil, effort: nil,
                        compaction: true))
                return (true, position)
            }
            Task { try? await startCompaction(instructions: instructions.isEmpty ? nil : instructions) }
            return (false, nil)
        }

        if pendingUI != nil {
            await resolvePendingUI(with: shown ?? text)
            return (false, nil)
        }

        let promptText = text
        if let wantEffort, wantEffort != effort {
            effort = wantEffort
            if let process {
                _ = await process.request(
                    "set_thinking_level", fields: ["level": wantEffort])
            }
        }
        if let wantModel, wantModel != model, !wantModel.isEmpty {
            let proc = try await ensureProcess()
            guard await applyModelOn(proc, wantModel) else {
                throw BridgeError.badRequest(
                    "This machine's oh-my-pi has no model called \(wantModel)")
            }
            model = wantModel
        }

        var userParts: [Part] = [.text(shown ?? text)]
        userParts.append(contentsOf: files.map { Part.file($0) })
        let userMessage = Message(
            id: "u-\(UUID().uuidString.prefix(8))", role: .user,
            parts: userParts, createdAt: Date(), seconds: nil, model: nil, usage: nil,
            costUSD: nil)
        messages.append(userMessage)
        titleFromFirstPrompt(shown ?? text)
        touch()
        await publish(.messageUpserted(userMessage))

        if running || compacting || !queued.isEmpty {
            let position = queued.count
            queued.append(QueuedPrompt(prompt: promptText, displayPrompt: shown ?? text, model: wantModel, effort: wantEffort))
            return (true, position)
        }
        try await startTurn(prompt: promptText, display: shown ?? text)
        return (false, nil)
    }

    /// How long a turn may go without a word from the engine before its liveness is questioned.
    private static let turnSilence: TimeInterval = 20

    /// A turn the engine has already dropped must not keep this session busy: oh-my-pi aborts
    /// the active turn for a manual compaction and can end a turn without a terminal
    /// `agent_end`, and a session that believes it is running queues every later prompt behind
    /// a turn that will never yield. When the engine has been silent for a while and says it is
    /// not streaming, the turn is closed here so the next prompt starts instead of waiting.
    private func healDeadTurn() async {
        guard running, pendingUI == nil,
            Date().timeIntervalSince(lastEventAt) > Self.turnSilence,
            let process
        else { return }
        let state = await process.request("get_state", timeout: 10)
        guard let data = state.data, data["isStreaming"]?.boolValue == false else { return }
        finishTurn()
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
        await journal?.write(
            JournalEntry(
                turnID: "t-\(UUID().uuidString.prefix(8))", sessionID: id,
                ompSessionFile: ompSessionFile, prompt: display, startedAt: Date(),
                pid: await proc.processID))
        let response = await proc.request("prompt", fields: ["message": prompt])
        if !response.success, response.errorCode != "timeout", running {
            await publish(.error(response.error ?? "The prompt was refused"))
            finishTurn()
            return
        }
        await syncState(from: proc)
    }

    private func syncState(from proc: OmpProcess) async {
        let state = await proc.request("get_state", timeout: 15)
        guard let data = state.data else { return }
        if let file = data["sessionFile"]?.stringValue { ompSessionFile = file }
        if let sid = data["sessionId"]?.stringValue { ompSessionID = sid }
        if let model = data["model"]?["id"]?.stringValue, model != self.model {
            self.model = model
        }
        if let level = data["thinkingLevel"]?.stringValue {
            effort = level
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

    /// A manual compaction, run only between turns: oh-my-pi's `compact` aborts whatever turn
    /// is active, so `send` queues the request behind a running one rather than calling this.
    /// The seam is appended to the transcript before the finish is announced, because the
    /// clients hold a "compacting" card until the seam they were promised is among the rows.
    func startCompaction(instructions: String?) async throws {
        guard !compacting else {
            throw BridgeError.conflict("A compaction is already running")
        }
        guard !running else {
            throw BridgeError.conflict("A turn is running")
        }
        let proc = try await ensureProcess()
        compacting = true
        let startedAt = Date()
        compactionStartedAt = startedAt
        await quietRegistry.increment()
        await publish(.compaction(phase: "started", error: nil))
        var fields: [String: Any] = [:]
        if let instructions, !instructions.isEmpty { fields["customInstructions"] = instructions }
        let response = await proc.request("compact", fields: fields, timeout: 900)
        compacting = false
        compactionStartedAt = nil
        await quietRegistry.decrement()
        if response.success {
            await recordCompaction(trigger: "manual", result: response.data, startedAt: startedAt)
            await publish(.compaction(phase: "finished", error: nil))
        } else {
            await publish(.compaction(phase: "failed", error: response.error))
        }
        await drainQueue()
    }

    /// How many times, and how far apart, the transcript is re-read for the seam oh-my-pi
    /// writes after its compaction has answered.
    private static let seamReads = 8
    private static let seamReadGap: Duration = .milliseconds(250)

    /// Puts the seam a compaction just left into the transcript and on the wire. The entry in
    /// oh-my-pi's own file is the authority — it alone knows the size the context shrank to —
    /// and the RPC result stands in when the file has not been written yet, so a compaction
    /// that succeeded never finishes without a seam.
    private func recordCompaction(trigger: String, result: JSONValue?, startedAt: Date) async {
        var entry: JSONValue?
        if let file = ompSessionFile {
            for attempt in 0..<Self.seamReads {
                if let found = TranscriptLoader.lastCompaction(inFile: file),
                    !messages.contains(where: { $0.id == "c-\(found["id"]?.stringValue ?? "")" })
                {
                    entry = found
                    break
                }
                if attempt + 1 < Self.seamReads { try? await Task.sleep(for: Self.seamReadGap) }
            }
        }
        var seam: Message
        if let entry {
            seam = TranscriptLoader.seam(entry, trigger: trigger)
        } else if let result {
            seam = TranscriptLoader.seam(result, trigger: trigger)
        } else {
            seam = TranscriptLoader.seam(JSONValue.from([String: Any]()), trigger: trigger)
        }
        if case .compaction(var compaction) = seam.parts[0] {
            compaction.durationMs = Date().timeIntervalSince(startedAt) * 1000
            seam.parts[0] = .compaction(compaction)
        }
        seam.createdAt = Date()
        messages.append(seam)
        touch()
        await publish(.messageUpserted(seam))
    }

    private func drainQueue() async {
        guard !running, !compacting, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        do {
            if next.compaction == true {
                try await startCompaction(instructions: next.prompt.isEmpty ? nil : next.prompt)
                return
            }
            if let wantEffort = next.effort, wantEffort != effort {
                effort = wantEffort
                let proc = try await ensureProcess()
                _ = await proc.request("set_thinking_level", fields: ["level": wantEffort])
            }
            if let wantModel = next.model, wantModel != model, !wantModel.isEmpty {
                let proc = try await ensureProcess()
                if await applyModelOn(proc, wantModel) {
                    model = wantModel
                } else {
                    await publish(
                        .error("This machine's oh-my-pi has no model called \(wantModel); staying on \(model)"))
                }
            }
            try await startTurn(prompt: next.prompt, display: next.displayPrompt)
        } catch {
            await publish(.error(error.localizedDescription))
        }
    }

    private func finishTurn() {
        guard running else { return }
        running = false
        let unfinished = closeLiveMessage()
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
            if let unfinished { await publish(.messageUpserted(unfinished)) }
            await publish(.status("idle"))
            await journal?.clear(id)
            await quietRegistry.decrement()
            await drainQueue()
        }
    }

    /// Assembles and appends whatever the live message holds when a turn ends without its own
    /// `message_end` — an abort, a dead process, an `agent_end` that outran the stream — so the
    /// partial answer survives in the transcript instead of evaporating with the live buffer.
    private func closeLiveMessage() -> Message? {
        guard liveMessageID != nil, let assembled = liveMessageSnapshot(final: true) else {
            return nil
        }
        messages.append(assembled)
        touch()
        liveMessageID = nil
        liveParts = []
        return assembled
    }

    private func liveMessageSnapshot(final: Bool = false) -> Message? {
        guard let id = liveMessageID, let created = liveCreatedAt else { return nil }
        return Message(
            id: id, role: .assistant, parts: materializedParts(), createdAt: created,
            seconds: final ? turnStartedAt.map { Date().timeIntervalSince($0) } : nil,
            model: liveModel, usage: final ? liveUsage : nil, context: liveContext,
            costUSD: final ? liveCost : nil)
    }

    /// A mid-turn transcript sync point: the whole live message, republished at most four times a
    /// second. Reasoning and tool-input streaming ride on this rather than on `delta` frames,
    /// because the wire's delta channel is untyped text and would write thinking into the answer.
    private func publishLiveSnapshot(force: Bool = false) async {
        guard let snapshot = liveMessageSnapshot() else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastSnapshotAt) >= 0.25 else { return }
        lastSnapshotAt = now
        await publish(.messageUpserted(snapshot))
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

    func handleOmpEvent(_ frame: JSONValue) async {
        let type = frame["type"]?.stringValue ?? ""
        lastEventAt = Date()
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
                compactionStartedAt = Date()
                await publish(.compaction(phase: "started", error: nil))
            }
        case "auto_compaction_end":
            if frame["skipped"]?.boolValue == true { break }
            compacting = false
            let startedAt = compactionStartedAt ?? Date()
            compactionStartedAt = nil
            let failed = frame["aborted"]?.boolValue == true
            if !failed {
                await recordCompaction(trigger: "auto", result: frame["result"], startedAt: startedAt)
            }
            await publish(
                .compaction(phase: failed ? "failed" : "finished",
                            error: failed ? "Aborted" : nil))
            if !running { await drainQueue() }
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
            liveContext = nil
            liveCost = 0
            liveModel = message["model"]?.stringValue ?? liveModel
            lastSnapshotAt = .distantPast
            if let id = liveMessageID, let created = liveCreatedAt {
                await publish(
                    .messageUpserted(
                        Message(
                            id: id, role: .assistant, parts: [.text("")], createdAt: created,
                            seconds: nil, model: liveModel, usage: nil, costUSD: nil)))
            }
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
            appendToLiveReasoning(event["delta"]?.stringValue ?? "")
            await publishLiveSnapshot()
        case "toolcall_start":
            liveParts.append(
                .tool(ToolCall(id: "pending-\(liveParts.count)", name: "", input: "", status: .running)))
        case "toolcall_delta":
            let delta = event["delta"]?.stringValue ?? ""
            if let index = lastLiveToolIndex() {
                updateToolPart(index: index) { $0.input += delta }
                await publishLiveSnapshot()
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
            if let assembled = closeLiveMessage() {
                await publish(.messageUpserted(assembled))
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
        liveContext = counts
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
            await publishTool(at: index)
            let partsBefore = liveParts.count
            await attachResultFiles(frame, toolCallID: toolCallID)
            if liveParts.count != partsBefore {
                await publishLiveSnapshot(force: true)
            }
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

    private func adoptTranscriptIfNeeded() {
        guard messages.isEmpty, let file = ompSessionFile else { return }
        let loaded = TranscriptLoader.load(sessionFile: file)
        if !loaded.messages.isEmpty {
            messages = loaded.messages
            adoptSpend(from: loaded.messages)
            ompSessionID = loaded.sessionID
            if let first = loaded.firstUserText, !customTitle {
                title = Self.derivedTitle(from: first)
                autoTitled = true
            }
        }
    }

    static let externalActivityWindow: TimeInterval = 180

    /// The ledger of a transcript the bridge did not run — one started in a terminal, or one that
    /// grew there while the bridge was idle — read off the usage every assistant message carries.
    /// A turn is a prompt and everything the model said before the next one; its tokens are the
    /// sum of those messages, its calls the tool calls among them, and its price what oh-my-pi
    /// itself wrote beside each message. Without this a session adopted from disk priced at zero
    /// and never moved, whatever the machine had spent.
    private func adoptSpend(from messages: [Message]) {
        turns = Self.turns(from: messages)
        totalCostUSD = turns.reduce(0) { $0 + $1.costUSD }
        totalTokens = turns.reduce(TokenCounts()) { $0 + $1.tokens }
    }

    static func turns(from messages: [Message]) -> [TurnRecord] {
        var records: [TurnRecord] = []
        var current: TurnRecord?
        var lastAt: Date?
        func close() {
            guard var record = current else { return }
            if let lastAt { record.seconds = lastAt.timeIntervalSince(record.at) }
            records.append(record)
            current = nil
        }
        for message in messages {
            switch message.role {
            case .user:
                close()
                let prompt = message.parts.compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined(separator: "\n")
                current = TurnRecord(
                    at: message.createdAt, seconds: nil, model: nil, calls: 0,
                    tokens: TokenCounts(), costUSD: 0, prompt: prompt.isEmpty ? nil : prompt)
                lastAt = nil
            case .assistant:
                if current == nil {
                    current = TurnRecord(
                        at: message.createdAt, seconds: nil, model: nil, calls: 0,
                        tokens: TokenCounts(), costUSD: 0, prompt: nil)
                }
                if let model = message.model { current?.model = model }
                if let usage = message.usage, let sum = current?.tokens { current?.tokens = sum + usage }
                current?.costUSD += message.costUSD ?? 0
                current?.calls += message.parts.filter {
                    if case .tool = $0 { return true }
                    return false
                }.count
                lastAt = message.createdAt
            case .system:
                continue
            }
        }
        close()
        return records.filter { $0.tokens.total > 0 || $0.costUSD > 0 || $0.calls > 0 }
            .map { record in
                var fixed = record
                fixed.calls = max(fixed.calls, 1)
                return fixed
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
        adoptSpend(from: loaded.messages)
        if let id = ompID ?? loaded.sessionID { ompSessionID = id }
        if let cwd = loaded.cwd { directory = cwd }
        if let model = loaded.model, model != self.model { self.model = model }
        if let effort = loaded.effort { self.effort = effort }
        if let first = loaded.firstUserText, !customTitle {
            title = Self.derivedTitle(from: first)
            autoTitled = true
        }
        if let created = loaded.messages.first?.createdAt { createdAt = created }
        if let updated = loaded.updatedAt { updatedAt = max(updated, createdAt) }
    }

    func refreshFromTranscriptIfIdle() async {
        guard !running, compacting == false, queued.isEmpty, let file = ompSessionFile else {
            externallyLive = false
            return
        }
        let mtime = TranscriptLoader.mtime(file)
        let threshold = Date().addingTimeInterval(-Self.externalActivityWindow)
        externallyLive = (mtime ?? .distantPast) > threshold
        guard mtime != lastTranscriptMtime else { return }
        lastTranscriptMtime = mtime
        let loaded = TranscriptLoader.load(sessionFile: file)
        if loaded.messages.count != messages.count {
            await adoptExternally(loaded: loaded, ompID: loaded.sessionID)
            touch()
        }
    }

    func sessionFile() -> String? { ompSessionFile }
}
