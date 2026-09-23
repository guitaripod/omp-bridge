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
    let forkedAt: Date?
    private(set) var messages: [Message] = []
    private(set) var customTitle = false
    private(set) var autoTitled = false
    private var titling = false

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
    private var transcriptActivity = TranscriptActivity()
    /// The moment this bridge's own last turn was over. What its engine wrote up to then belongs to
    /// that turn, never to one somebody is running from a terminal — even when the engine died with
    /// a tool call still open.
    private var ownTurnSettledAt = Date.distantPast
    private var turnStartedAt: Date?
    private var turnPrompt: String?
    private var turnCalls = 0
    private var turnTokens = TokenCounts()
    private var turnCost = 0.0
    private var turnHadContent = false
    private var turnLastErrorMessage: String?
    /// Pending tool-call parts by the engine's `contentIndex`, so parallel calls in one message
    /// are keyed by the index that names them rather than by whichever happened to land last.
    private var pendingContentIndexes: [Int: Int] = [:]

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
        restoredDates: (createdAt: Date, updatedAt: Date)? = nil, forkedAt: Date? = nil,
        namedByHand: Bool = false, namedByModel: Bool = false
    ) {
        self.id = id
        self.title = title
        self.customTitle = namedByHand
        self.autoTitled = namedByModel
        self.directory = directory
        self.model = model
        self.effort = effort
        self.ompSessionFile = ompSessionFile
        self.createdAt = restoredDates?.createdAt ?? forkedAt ?? Date()
        self.updatedAt = restoredDates?.updatedAt ?? forkedAt ?? Date()
        self.forkedAt = forkedAt
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
    ///
    /// The name this leaves is provisional: `autoTitled` stays false so the model-written title
    /// can still land on top of it once the first turn has an answer to read.
    private func titleFromFirstPrompt(_ text: String) {
        guard !customTitle, !autoTitled, Self.isPlaceholderTitle(title) else { return }
        let derived = Self.derivedTitle(from: text)
        guard derived != "New chat" else { return }
        title = derived
    }

    /// A conversation is named by a model once there is an exchange to name — a short `omp -p`
    /// call on the session's own engine, which is the one already warm on this machine. omp's own
    /// title row is never filled in under the bridge, so this is the only thing that turns a slice
    /// of first prompt into a name. A rename by hand always wins, including against a call already
    /// in flight, and a failed call simply leaves the provisional name standing.
    func autoTitleIfUnnamed() {
        guard let call = titleCall() else { return }
        Task { [weak self] in
            await self?.applyAutoTitle(await Self.write(call))
        }
    }

    /// The same naming, awaited, so the backfill of sessions that were named before there was a
    /// namer can walk them one at a time — twenty calls at once would each pay for loading a cold
    /// engine.
    func autoTitleNow() async {
        guard let call = titleCall() else { return }
        applyAutoTitle(await Self.write(call))
    }

    private struct TitleCall: Sendable {
        let binary: String
        let model: String?
        let cwd: String
        let user: String
        let assistant: String
    }

    private static func write(_ call: TitleCall) async -> String? {
        await Titler.title(
            binary: call.binary, model: call.model, cwd: call.cwd, user: call.user,
            assistant: call.assistant)
    }

    private func titleCall() -> TitleCall? {
        guard !customTitle, !autoTitled, !titling,
            let user = firstText(of: .user),
            let assistant = firstText(of: .assistant) ?? firstReasoning()
        else { return nil }
        titling = true
        return TitleCall(
            binary: config.ompBin, model: config.titleModel ?? (model.isEmpty ? nil : model),
            cwd: config.titlerWorkdir, user: user, assistant: assistant)
    }

    /// The name lands without touching `updatedAt`: a title written minutes or days after the
    /// last word was said must not shuffle the chat back to the top of the list.
    private func applyAutoTitle(_ written: String?) {
        titling = false
        guard let written, !customTitle, !autoTitled else { return }
        title = written
        autoTitled = true
    }

    /// The first thing this side of the conversation actually said. Not simply the first message:
    /// an engine that opens a turn with thinking, or with a tool call it narrates later, leaves a
    /// message whose text is empty, and a title read off that one would never be asked for.
    private func firstText(of role: Role) -> String? {
        for message in messages where message.role == role {
            let text = message.parts.compactMap { part in
                if case .text(let value) = part { return value }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// What the engine was thinking, for a turn that said nothing out loud. A coding turn is often
    /// all tool calls and reasoning — real work, and nothing a title could be read off without
    /// this.
    private func firstReasoning() -> String? {
        for message in messages where message.role == .assistant {
            for part in message.parts {
                guard case .reasoning(let value) = part else { continue }
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "New chat" || trimmed.hasPrefix("New session")
    }

    /// A name is not something said, so it leaves the chat where the conversation put it — as
    /// the model's title does, and as the transcript's own clock will after the next restart.
    func rename(_ newTitle: String) {
        title = newTitle
        customTitle = true
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
    /// How far apart the engine is asked, once a turn has gone quiet, and how many times in a row
    /// it has to say it is not streaming before the turn is called over — one answer taken alone
    /// would close a turn whose only silence is a long tool call.
    private static let healProbeGap: TimeInterval = 10
    private static let healStrikesToClose = 2
    private var lastHealProbeAt = Date.distantPast
    private var healStrikes = 0

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
        guard await process.isRunning else {
            await publish(.error("The oh-my-pi process exited before the turn ended."))
            finishTurn()
            return
        }
        let state = await process.request("get_state", timeout: 10)
        guard let data = state.data, data["isStreaming"]?.boolValue == false else { return }
        finishTurn()
    }

    /// The same healing on the bridge's own clock, so a dead turn is closed while nobody is
    /// sending rather than on the next prompt — which is the one that never went, because it was
    /// queued behind the turn that had died. Asked at most once every ``healProbeGap`` and only
    /// after two consecutive answers agree: a single "not streaming" can be a tool that has been
    /// running quietly for a while.
    func healIfStale() async {
        guard running, pendingUI == nil,
            Date().timeIntervalSince(lastEventAt) > Self.turnSilence,
            Date().timeIntervalSince(lastHealProbeAt) > Self.healProbeGap
        else {
            if !running { healStrikes = 0 }
            return
        }
        lastHealProbeAt = Date()
        guard let process, await process.isRunning else {
            healStrikes = 0
            await publish(.error("The oh-my-pi process exited before the turn ended."))
            finishTurn()
            return
        }
        let state = await process.request("get_state", timeout: 10)
        guard let data = state.data, data["isStreaming"]?.boolValue == false else {
            healStrikes = 0
            return
        }
        healStrikes += 1
        guard healStrikes >= Self.healStrikesToClose else { return }
        healStrikes = 0
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
        if let model = Self.qualifiedModel(inState: data), model != self.model {
            self.model = model
        }
        effort = data["thinkingLevel"]?.stringValue ?? ""
    }

    /// The engine's model in `provider/id` form, the shape the transcript's own `model_change`
    /// rows use. Reading only the id left one session saying "qwen38-nvfp4" and the next
    /// "llama-swap/qwen38-nvfp4" for the same engine, and a client matching against its
    /// catalog could resolve only one of them.
    private static func qualifiedModel(inState data: JSONValue) -> String? {
        guard let id = data["model"]?["id"]?.stringValue, !id.isEmpty else { return nil }
        guard let provider = data["model"]?["provider"]?.stringValue, !provider.isEmpty else { return id }
        return "\(provider)/\(id)"
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
        settleOwnTurn()
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
        settleOwnTurn()
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
        let settled = settleDanglingTools()
        autoTitleIfUnnamed()
        Task {
            if let unfinished { await publish(.messageUpserted(unfinished)) }
            for message in settled where message.id != unfinished?.id {
                await publish(.messageUpserted(message))
            }
            await publish(.status("idle"))
            await journal?.clear(id)
            await quietRegistry.decrement()
            await drainQueue()
        }
    }

    /// A tool the turn never heard back from. The engine reports every execution it finishes, so
    /// a call still running once the turn is over is one whose result died with the process — and
    /// a running call is drawn as work in progress on every client for as long as the transcript
    /// survives. Settle it as ended rather than leaving a spinner nobody can stop, and hand back
    /// the messages that changed so the wire says so too.
    private func settleDanglingTools() -> [Message] {
        var changed: [Message] = []
        for index in messages.indices.reversed() {
            guard messages[index].role == .assistant else { continue }
            var touched = false
            for partIndex in messages[index].parts.indices {
                guard case .tool(var call) = messages[index].parts[partIndex],
                    call.status == .running
                else { continue }
                call.status = .stopped
                messages[index].parts[partIndex] = .tool(call)
                touched = true
            }
            if touched { changed.append(messages[index]) }
        }
        if !changed.isEmpty { touch() }
        return changed
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
        pendingContentIndexes = [:]
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
        if let seat = seatOfToolPart(ui.toolCallID) {
            mutateToolPart(seat) { tool in
                tool.status = .error
                tool.output = "Unanswered"
            }
            let seatToPublish = seat
            Task { [weak self] in await self?.publishTool(seatToPublish) }
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
        if let seat = seatOfToolPart(ui.toolCallID) {
            mutateToolPart(seat) { tool in
                tool.status = .completed
                tool.output = "Your questions have been answered: \"\(ui.message ?? "")\"=\"\(answerLabel)\"."
            }
            await publishTool(seat)
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
        case "process_exited":
            /// The engine went away under a turn. Nothing else will ever close it, so it is
            /// closed here with its reason, and the next prompt starts a fresh engine.
            process = nil
            if compacting {
                compacting = false
                compactionStartedAt = nil
                await quietRegistry.decrement()
                await publish(.compaction(phase: "failed", error: "The oh-my-pi process exited"))
            }
            if running {
                await publish(.error("The oh-my-pi process exited before the turn ended."))
                finishTurn()
            }
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
            knownCommands = CommandCatalog.parse(frame["commands"]?.arrayValue ?? [])
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
            pendingContentIndexes = [:]
            liveUsage = TokenCounts()
            liveContext = nil
            liveCost = 0
            liveModel = TranscriptLoader.qualifiedModel(in: message) ?? liveModel
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
            let pending = ToolCall(
                id: "pending-\(liveParts.count)", name: "", input: "", status: .running)
            pendingContentIndexes[event["contentIndex"]?.intValue ?? -1] = liveParts.count
            liveParts.append(.tool(pending))
        case "toolcall_delta":
            let delta = event["delta"]?.stringValue ?? ""
            if let index = pendingToolIndex(for: event) {
                mutateToolPart(.live(index)) { $0.input += delta }
                await publishLiveSnapshot()
            }
        case "toolcall_end":
            if let call = event["toolCall"], let index = pendingToolIndex(for: event) {
                let arguments = Self.serializeArguments(call["arguments"])
                mutateToolPart(.live(index)) { tool in
                    tool.id = call["id"]?.stringValue ?? tool.id
                    tool.name = call["name"]?.stringValue ?? tool.name
                    tool.input = arguments
                }
                pendingContentIndexes.removeValue(
                    forKey: event["contentIndex"]?.intValue ?? -1)
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

    private func pendingToolIndex(for event: JSONValue) -> Int? {
        if let index = pendingContentIndexes[event["contentIndex"]?.intValue ?? -1] {
            return index
        }
        return liveParts.lastIndex { if case .tool = $0 { return true }; return false }
    }

    /// Where a tool call lives. The engine closes an assistant message the moment it names its
    /// tool calls, then reports each execution against it — so by the time `tool_execution_end`
    /// arrives the call has almost always moved out of the live buffer and into ``messages``, and
    /// a completion that only knows how to touch one of the two is a spinner nobody can turn off.
    enum ToolSeat {
        case live(Int)
        case settled(messageID: String, messageIndex: Int, partIndex: Int)
    }

    private func seatOfToolPart(_ toolID: String) -> ToolSeat? {
        if let index = liveParts.lastIndex(where: { part in
            if case .tool(let call) = part { return call.id == toolID }
            return false
        }) { return .live(index) }
        for messageIndex in messages.indices.reversed() {
            if let partIndex = messages[messageIndex].parts.lastIndex(where: { part in
                if case .tool(let call) = part { return call.id == toolID }
                return false
            }) {
                return .settled(
                    messageID: messages[messageIndex].id, messageIndex: messageIndex,
                    partIndex: partIndex)
            }
        }
        return nil
    }

    private func mutateToolPart(_ seat: ToolSeat, _ mutate: (inout ToolCall) -> Void) {
        switch seat {
        case .live(let index):
            if liveParts.indices.contains(index), case .tool(var call) = liveParts[index] {
                mutate(&call)
                liveParts[index] = .tool(call)
            }
        case .settled(let messageID, let messageIndex, let partIndex):
            guard messages.indices.contains(messageIndex),
                messages[messageIndex].id == messageID,
                messages[messageIndex].parts.indices.contains(partIndex),
                case .tool(var call) = messages[messageIndex].parts[partIndex]
            else { return }
            mutate(&call)
            messages[messageIndex].parts[partIndex] = .tool(call)
            touch()
        }
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
        if let model = TranscriptLoader.qualifiedModel(in: message) { liveModel = model }
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
        if let seat = seatOfToolPart(toolCallID) {
            mutateToolPart(seat) { tool in
                tool.id = toolCallID
                tool.name = name
                if tool.input.isEmpty { tool.input = args }
                tool.status = .running
            }
            await publishTool(seat)
        }
    }

    private func handleExecutionUpdate(_ frame: JSONValue) async {
        guard let toolCallID = frame["toolCallId"]?.stringValue else { return }
        let texts = (frame["partialResult"]?["content"]?.arrayValue ?? []).compactMap {
            $0["text"]?.stringValue
        }
        let output = texts.joined()
        if let seat = seatOfToolPart(toolCallID) {
            mutateToolPart(seat) { tool in
                tool.output = String(output.prefix(10_000))
            }
            await publishTool(seat)
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
        guard let seat = seatOfToolPart(toolCallID) else { return }
        mutateToolPart(seat) { tool in
            tool.status = isError ? .error : .completed
            tool.output = String(output.prefix(10_000))
        }
        await publishTool(seat)
        let attached = attachResultFiles(frame, toolCallID: toolCallID)
        if case .live = seat, attached {
            await publishLiveSnapshot(force: true)
        }
    }

    private func attachResultFiles(_ frame: JSONValue, toolCallID: String) -> Bool {
        guard let contents = frame["result"]?["content"]?.arrayValue else { return false }
        guard let seat = seatOfToolPart(toolCallID) else { return false }
        var attached = false
        for content in contents {
            guard let path = content["path"]?.stringValue ?? content["filePath"]?.stringValue,
                isImagePath(path)
            else { continue }
            let filename = (path as NSString).lastPathComponent
            let mime = mimeForExtension(filename)
            let url =
                "/files/raw?path=\(Self.percentEncode(path))&tool=\(Self.percentEncode(toolCallID))&session=\(Self.percentEncode(ompSessionID ?? id))"
            let fileRef = FileRef(path: path, mime: mime, filename: filename, url: url)
            switch seat {
            case .live(let index):
                liveParts.insert(.file(fileRef), at: min(index + 1, liveParts.count))
            case .settled(let messageID, let messageIndex, let partIndex):
                guard messages.indices.contains(messageIndex),
                    messages[messageIndex].id == messageID,
                    messages[messageIndex].parts.indices.contains(partIndex)
                else { continue }
                messages[messageIndex].parts.insert(
                    .file(fileRef), at: min(partIndex + 1, messages[messageIndex].parts.count))
            }
            attached = true
        }
        return attached
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

    private func publishTool(_ seat: ToolSeat) async {
        let found = toolCall(at: seat)
        guard let (messageID, call) = found else { return }
        await publish(.toolUpserted(messageID: messageID, call))
    }

    private func publishTool(_ call: ToolCall, messageID: String) async {
        await publish(.toolUpserted(messageID: messageID, call))
    }

    /// The call a seat names, with the message id a client needs to seat an upsert of it.
    private func toolCall(at seat: ToolSeat) -> (messageID: String, call: ToolCall)? {
        switch seat {
        case .live(let index):
            guard let messageID = liveMessageID, liveParts.indices.contains(index),
                case .tool(let call) = liveParts[index]
            else { return nil }
            return (messageID, call)
        case .settled(let messageID, let messageIndex, let partIndex):
            guard messages.indices.contains(messageIndex),
                messages[messageIndex].id == messageID,
                messages[messageIndex].parts.indices.contains(partIndex),
                case .tool(let call) = messages[messageIndex].parts[partIndex]
            else { return nil }
            return (messageID, call)
        }
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
            if let first = loaded.firstUserText, !customTitle, !autoTitled {
                title = Self.derivedTitle(from: first)
            }
        }
    }

    static let externalActivityWindow: TimeInterval = 180
    /// How long after this bridge closed its own turn a row the engine files is still that turn's
    /// tail — an abort's last words land a moment after the abort has answered.
    static let ownTailSlack: TimeInterval = 5

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

    /// A readable row title from a raw prompt: the first line that says something, whitespace
    /// collapsed, cut at a word boundary and given a capital where one is wanted. The
    /// model-written title replaces this once the first turn lands; until then this is the whole
    /// of what a list can say about the chat, so a prompt that is one slash command is worth what
    /// was asked of it rather than the command line itself.
    static func derivedTitle(from text: String, fallback: String = "New chat") -> String {
        let lines = text
            .replacingOccurrences(of: "<[^>]{1,80}>", with: " ", options: .regularExpression)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var title = spoken(in: lines) else { return fallback }
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if title.count > 48 {
            let head = String(title.prefix(48))
            if let space = head.lastIndex(of: " "),
                head.distance(from: head.startIndex, to: space) > 24
            {
                title = String(head[..<space]) + "…"
            } else {
                title = head + "…"
            }
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;–—-"))
        guard !title.isEmpty else { return fallback }
        return capitalizedLeadingWord(title)
    }

    /// What a prompt is actually about, given its lines. A leading slash command is worth its
    /// argument — "/flyr Tel Aviv" is a chat about Tel Aviv — and a bare command yields to the
    /// next line that is not one, falling back to its own name when there is nothing else.
    private static func spoken(in lines: [String]) -> String? {
        guard let first = lines.first else { return nil }
        guard first.hasPrefix("/") else { return first }
        let parts = first.dropFirst().split(separator: " ", maxSplits: 1)
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        if !argument.isEmpty { return argument }
        if let spelled = lines.dropFirst().first(where: { !$0.hasPrefix("/") }) { return spelled }
        guard let command = parts.first, !command.isEmpty else { return nil }
        return command.replacingOccurrences(of: "-", with: " ")
    }

    /// A sentence capital, but never one that rewrites a name the person spelled: a first word
    /// carrying a capital of its own ("iPhone", "macOS", "SwiftUI") is left exactly as typed.
    private static func capitalizedLeadingWord(_ title: String) -> String {
        let word = title.prefix { $0 != " " }
        guard !word.contains(where: \.isUppercase) else { return title }
        return title.prefix(1).uppercased() + title.dropFirst()
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
    func externallyLiveValue() -> Bool { externallyLive }
    func pendingInterruption() -> Interruption? { nil }

    func summarySnapshot() -> SessionSummary { summary }

    func adoptExternally(loaded: LoadedTranscript, ompID: String?) async {
        messages = loaded.messages
        adoptSpend(from: loaded.messages)
        if let id = ompID ?? loaded.sessionID { ompSessionID = id }
        if let cwd = loaded.cwd { directory = cwd }
        if let model = loaded.model, model != self.model { self.model = model }
        if let effort = loaded.effort { self.effort = effort }
        if let first = loaded.firstUserText, !customTitle, !autoTitled {
            title = Self.derivedTitle(from: first)
        }
        if let created = loaded.messages.first?.createdAt { createdAt = forkedAt ?? created }
        if let updated = loaded.updatedAt { updatedAt = max(updated, createdAt) }
        transcriptActivity = loaded.activity
        lastTranscriptMtime = loaded.modifiedAt
    }

    /// Follows a transcript that something other than this bridge's own turn is writing. The chat's
    /// clock moves only with what is said in it and it reads live only while a turn is open there,
    /// so the rows an engine files on its way out — one for every chat a restart closed — neither
    /// move a chat to the top nor wear it as live.
    func refreshFromTranscriptIfIdle() async {
        guard !running, compacting == false, queued.isEmpty, let file = ompSessionFile else {
            externallyLive = false
            return
        }
        let mtime = TranscriptLoader.mtime(file)
        if mtime != lastTranscriptMtime {
            lastTranscriptMtime = mtime
            let loaded = TranscriptLoader.load(sessionFile: file)
            transcriptActivity = loaded.activity
            if loaded.messages.count != messages.count {
                await adoptExternally(loaded: loaded, ompID: loaded.sessionID)
            } else if let said = loaded.activity.lastSaid, said > updatedAt {
                updatedAt = said
            }
        }
        let horizon = max(
            Date().addingTimeInterval(-Self.externalActivityWindow),
            ownTurnSettledAt.addingTimeInterval(Self.ownTailSlack))
        externallyLive = transcriptActivity.isLive(after: horizon)
    }

    func settleOwnTurn() {
        ownTurnSettledAt = Date()
    }

    func sessionFile() -> String? { ompSessionFile }
}
