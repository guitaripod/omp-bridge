import Foundation

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
    var agentType: String?
    var toolUseID: String?
    var startedAt: Date?
    var toolCount: Int?
    var currentTool: String?
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
    private(set) var chapters: [Chapter] = []
    private(set) var chaptersRevision = 0
    /// The person's message count when the title was last written or confirmed by a look.
    private(set) var titledAtTurn: Int?
    /// Counts clears, so a title, look or split that was out while the conversation was cleared
    /// lands on nothing.
    private var conversationEpoch = 0
    private var backfillTried = false

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
    /// The journal entry the open turn wrote, so the end of this turn clears that entry and never
    /// the next turn's, which can be written before this turn's ending has finished publishing.
    private var journalTurnID: String?
    private var engineStartedAt = Date.distantPast
    /// The messages people queued behind the running turn, in arrival order. Held here rather
    /// than on each device so every client of the conversation sees and can change the same
    /// queue; a file in the state directory keeps it across a restart.
    private var queue: [HeldQueueItem] = []
    /// A Stop ended the running turn, or a restart brought the queue back and nobody has said to
    /// carry on. Cleared by a new message, an enqueue or a resume.
    private var queuePaused = false
    /// The newest ids of queue items that left the queue for a turn, so a retried enqueue does not
    /// run twice and a cancel can tell "already started" from "already gone".
    private var startedQueueIDs: [String] = []
    /// An item has left the queue, or a message has been accepted, and its turn or compaction has
    /// not opened yet. Counts as busy: the engine is about to be spoken to, and a second message
    /// arriving in the gap must queue behind it rather than start beside it.
    private var starting = false
    private var queueRestored = false
    private let queueURL: URL
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
    private var lastTranscriptLoadAt = Date.distantPast
    /// The transcript changed since it was last read in whole.
    private var transcriptBehind = false
    /// How often a transcript something else is writing is read back in whole. A terminal driving
    /// the conversation changes the file every second, and reading a transcript of many megabytes
    /// that often held this conversation's actor for most of each second; its tail, which says
    /// whether the turn is still open and when anything was last said, is still read on every
    /// change, and the end of the turn is read in whole at once.
    private static let transcriptReloadGap: TimeInterval = 3
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
    private var lastAgentsPublishAt = Date.distantPast
    /// The id the running turn's prompt was sent with, which its `prompt_result` repeats.
    private var turnRequestID: String?
    /// The prompt's result said its run yielded to background work, so the turn closes on the
    /// engine's `session_settled` rather than on the result.
    private var awaitingSettle = false
    private var agentsPublishTask: Task<Void, Never>?
    /// The wait between attempts the running turn is in, if any.
    private(set) var retryWait: RetryWait?
    private var toolPublishedAt: [String: Date] = [:]
    private var knownCommands: [AgentCommandDTO] = []
    /// What the last turn left behind, for a caller that shows up after it is already over —
    /// `GET /sessions/:id/wait` reads this the moment it finds nothing running. Cleared by
    /// nothing: it simply stands until the next turn overwrites it, which is exactly what a late
    /// caller wants to hear.
    private(set) var lastTurnOutcome: TurnOutcome?

    /// How a turn came to stop, which decides what ``TurnWait`` calls it. A cause the engine
    /// itself narrated (`agentEnd`) still has to read `turnHadContent`/`turnLastErrorMessage` to
    /// tell finished from answerless from failed; the other two are never ambiguous.
    private enum TurnEndCause {
        case agentEnd
        case processFailure
        case aborted
    }

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

    /// What `GET /sessions/:id/wait` needs of an outstanding ask: just enough to point a client at
    /// the row carrying it, never the question's own text — the transcript already has that.
    struct PendingQuestion: Sendable, Equatable {
        var messageID: String?
    }

    func pendingQuestion() -> PendingQuestion? {
        guard pendingUI != nil else { return nil }
        return PendingQuestion(messageID: liveMessageID)
    }

    func lastOutcomeSnapshot() -> TurnOutcome? { lastTurnOutcome }

    /// When the stretch of work the last turn belongs to began: the first turn since one that
    /// settled, so a wait held for settled work can say how long the person was waited on.
    private(set) var workBegan: Date?

    /// Whether anything will start a turn on its own or is still working for this conversation:
    /// a turn, a terminal driving the transcript, a queued prompt that is not paused, or a
    /// subagent still at work.
    func carriesWork() -> Bool {
        busy || externallyLive || (!queuePaused && !queue.isEmpty) || activeAgentCount > 0
    }

    /// Whether the last turn left something behind that would start another: a sub-agent still at
    /// work or a prompt queued to go. A turn that follows one of those is the same stretch of
    /// work however long the gap.
    private var endedCarrying = false

    /// A turn is starting. One that follows a settled stretch begins a new one.
    private func noteTurnStarted(at now: Date) {
        if let last = lastTurnOutcome, !endedCarrying,
            now.timeIntervalSince(last.endedAt) >= TurnWaitEngine.grace
        {
            workBegan = now
        } else if workBegan == nil {
            workBegan = now
        }
    }

    var summary: SessionSummary {
        SessionSummary(
            id: id, title: title, directory: directory, model: model, effort: effort,
            createdAt: createdAt, updatedAt: updatedAt,
            active: (running || externallyLive) ? true : nil,
            interrupted: nil,
            agents: activeAgentCount > 0 ? activeAgentCount : nil,
            scheduled: scheduleID == nil ? nil : true)
    }

    /// The schedule this conversation runs for, when a schedule made it.
    private(set) var scheduleID: String?
    /// The open turn is a scheduled run allowed to stay quiet.
    private var quietPending = false

    func setScheduleID(_ value: String?) { scheduleID = value }

    static func plainText(_ message: Message) -> String {
        message.parts.compactMap { part -> String? in
            if case .text(let value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }

    /// Sends a scheduled run's prompt: the person's words are what the conversation keeps, and a
    /// note to the model — stay quiet when nothing changed — rides only in what omp is handed. A
    /// run that has to queue behind a live turn queues as the words alone.
    func sendScheduled(text: String, model: String?, effort: String?, quiet: Bool) async
        -> ScheduledSend
    {
        let quietHere = quiet && !busy
        if quietHere { quietPending = true }
        do {
            let sent = try await send(
                text: quietHere ? text + ScheduleWording.quietNote : text, displayText: text,
                model: model, effort: effort)
            return sent.queued ? .queued(position: turnsAheadOfLastQueued()) : .started
        } catch {
            quietPending = false
            return .failed(String(describing: error))
        }
    }

    /// How many turns will end before the item just queued gets a turn of its own, which is what
    /// a schedule counts down: the turn running or starting now, and every prompt queued ahead. A
    /// queued compaction ends no turn, and the queue position alone left out the running turn, so
    /// a scheduled run was settled by the end of the turn in front of it.
    private func turnsAheadOfLastQueued() -> Int {
        let running = (self.running || starting) ? 1 : 0
        return running + queue.dropLast().filter { $0.item.kind != QueuedItem.commandKind }.count
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
        queueURL = QueueFile.url(stateDir: config.stateDir, sessionID: id)
        if let restored = QueueFile.load(from: queueURL) {
            queue = restored.items
            queuePaused = true
            queueRestored = true
            if !restored.paused {
                QueueFile.write(PersistedQueue(items: restored.items, paused: true), to: queueURL)
            }
        }
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
    ///
    /// Once named, every few of the person's messages the name is looked at again, and where the
    /// topic moved a chapter opens.
    func autoTitleIfUnnamed() {
        guard let call = titleCall() else {
            reviseTitleIfDue()
            return
        }
        Task { [weak self] in
            await self?.applyAutoTitle(await Self.write(call), for: call)
        }
    }

    /// The same naming, awaited, so the backfill of sessions that were named before there was a
    /// namer can walk them one at a time — twenty calls at once would each pay for loading a cold
    /// engine.
    func autoTitleNow() async {
        guard let call = titleCall() else { return }
        await applyAutoTitle(await Self.write(call), for: call)
    }

    private struct TitleCall: Sendable {
        let binary: String
        let model: String?
        let cwd: String
        let user: String
        let assistant: String
        let turn: Int
        let epoch: Int
    }

    private static func write(_ call: TitleCall) async -> String? {
        await Titler.title(
            binary: call.binary, model: call.model, cwd: call.cwd, user: call.user,
            assistant: call.assistant)
    }

    private func titleCall() -> TitleCall? {
        guard !customTitle, !autoTitled, !titling else { return nil }
        let opening = ChapterBook.opening(chapters, messages: messages)
        guard let user = opening?.user ?? firstText(of: .user),
            let assistant = opening?.answer ?? firstText(of: .assistant) ?? firstReasoning()
        else { return nil }
        titling = true
        return TitleCall(
            binary: config.ompBin, model: titlingModel, cwd: config.titlerWorkdir, user: user,
            assistant: assistant, turn: ChapterBook.prompts(in: messages).count,
            epoch: conversationEpoch)
    }

    private var titlingModel: String? { config.titleModel ?? (model.isEmpty ? nil : model) }

    /// The name lands without touching `updatedAt`: a title written minutes or days after the
    /// last word was said must not shuffle the chat back to the top of the list. The chapter the
    /// conversation is in takes it too.
    private func applyAutoTitle(_ written: String?, for call: TitleCall) async {
        titling = false
        guard let written, !customTitle, !autoTitled, call.epoch == conversationEpoch else { return }
        let prior = title
        title = written
        autoTitled = true
        titledAtTurn = max(titledAtTurn ?? 0, call.turn)
        if ChapterBook.renamed(&chapters, messages: messages, to: written, by: .model, priorTitle: prior) {
            await publishChapters()
        }
    }

    static let retitleEvery = 3

    /// Whether enough of the person's messages have gone by since the title was last written or
    /// confirmed to look again. A title written before turns were counted is due at once.
    static func retitleDue(turn: Int, titledAt: Int?) -> Bool {
        turn - (titledAt ?? 0) >= retitleEvery
    }

    /// Asks whether the conversation still wears the right name, with the person's newest messages
    /// and the latest answer. A name the person chose is not changed, but the topic can still move
    /// under it, so the look still runs and only the chapters follow it. A schedule's conversation
    /// is never looked at. One call per conversation is out at a time.
    private func reviseTitleIfDue() {
        guard customTitle || autoTitled, scheduleID == nil, !titling else { return }
        let turn = ChapterBook.prompts(in: messages).count
        guard Self.retitleDue(turn: turn, titledAt: titledAtTurn) else { return }
        let shown = ChapterBook.recent(messages, since: titledAtTurn, through: turn)
        guard !shown.isEmpty,
            let answer = messages.last(where: {
                $0.role == .assistant && !ChapterBook.text(of: $0).isEmpty
            }).map(ChapterBook.text(of:))
        else { return }
        titling = true
        let current = chapters.last?.title ?? title
        let texts = shown.map { ChapterBook.text(of: $0.message) }
        let turns = shown.map(\.turn)
        let binary = config.ompBin
        let engine = titlingModel
        let cwd = config.titlerWorkdir
        let epoch = conversationEpoch
        Task { [weak self] in
            let verdict = await Titler.revised(
                binary: binary, model: engine, cwd: cwd, current: current, prompts: texts,
                assistant: answer)
            await self?.applyRevision(verdict, shown: turns, turn: turn, epoch: epoch)
        }
    }

    /// Lands a look. A failed look stamps nothing, so the next turn asks again; a KEEP stamps when
    /// the title was last looked at; a rename renames the current chapter, never one the person
    /// named; a move opens a chapter at the message the look named and sums up the one it closed.
    /// Under a title the person pinned only the chapters change. A look a clear overtook is dropped.
    private func applyRevision(_ verdict: Titler.Verdict, shown: [Int], turn: Int, epoch: Int) async {
        titling = false
        guard epoch == conversationEpoch, scheduleID == nil, turn >= (titledAtTurn ?? 0) else { return }
        let pinned = customTitle
        switch verdict {
        case .failed:
            return
        case .kept:
            titledAtTurn = turn
        case .renamed(let renamed):
            titledAtTurn = turn
            guard chapters.last?.namedBy != .person else { return }
            let prior = chapters.last?.title ?? title
            if !pinned { title = renamed }
            if ChapterBook.renamed(
                &chapters, messages: messages, to: renamed, by: .model, priorTitle: prior)
            {
                await publishChapters()
            }
        case .moved(let moved, let start):
            titledAtTurn = turn
            guard shown.indices.contains(start - 1) else { return }
            let prior = chapters.last?.title ?? title
            if !pinned { title = moved }
            let closed = ChapterBook.opened(
                &chapters, messages: messages, title: moved, atTurn: shown[start - 1],
                priorTitle: prior)
            if closed == nil, chapters.last?.namedBy != .person {
                ChapterBook.renamed(&chapters, messages: messages, to: moved, by: .model, priorTitle: prior)
            }
            await publishChapters()
            if let closed { sumUp(closed: closed) }
        }
    }

    /// Writes the closed chapter's one-sentence gist in the background. A failed call leaves the
    /// chapter without one; nothing retries.
    private func sumUp(closed index: Int) {
        guard chapters.indices.contains(index),
            let input = ChapterBook.gistInput(chapters, messages: messages, closed: index)
        else { return }
        let chapter = chapters[index]
        let binary = config.ompBin
        let engine = titlingModel
        let cwd = config.titlerWorkdir
        Task { [weak self] in
            guard let gist = await Titler.gist(
                binary: binary, model: engine, cwd: cwd, title: chapter.title,
                prompts: input.prompts, answer: input.answer)
            else { return }
            await self?.applyGist(gist, to: chapter)
        }
    }

    private func applyGist(_ gist: String, to chapter: Chapter) async {
        guard ChapterBook.summed(&chapters, chapter: chapter, gist: gist) else { return }
        await publishChapters()
    }

    /// Splits a conversation older than chapters into them, once, the first time it is read with
    /// enough history. A conversation that gains chapters of its own meanwhile keeps those.
    func backfillChaptersIfNeeded() {
        guard !backfillTried, !titling, chapters.isEmpty, scheduleID == nil, !busy else { return }
        let shown = ChapterBook.backfillPrompts(messages)
        guard shown.count >= ChapterBook.backfillFloor else { return }
        backfillTried = true
        titling = true
        let current = title
        let texts = shown.map { ChapterBook.text(of: $0.message) }
        let binary = config.ompBin
        let engine = titlingModel
        let cwd = config.titlerWorkdir
        let epoch = conversationEpoch
        Task { [weak self] in
            let segments = await Titler.segments(
                binary: binary, model: engine, cwd: cwd, current: current, prompts: texts)
            await self?.applyBackfill(segments, shown: shown, epoch: epoch)
        }
    }

    private func applyBackfill(
        _ segments: [Titler.Segment]?, shown: [(turn: Int, message: Message)], epoch: Int
    ) async {
        titling = false
        guard let segments, epoch == conversationEpoch,
            let split = ChapterBook.backfilled(
                chapters, messages: messages, title: title, customTitle: customTitle,
                segments: segments, shown: shown)
        else { return }
        chapters = split
        await publishChapters()
    }

    /// The chapters changed: the change is counted and every client watching is handed the whole
    /// list with its count. The store writes them down on its next sweep, which compares the count.
    private func publishChapters() async {
        chaptersRevision += 1
        await publish(
            .chapters(
                ChapterBook.resolved(chapters, messages: snapshotMessages()),
                revision: chaptersRevision))
    }

    /// The chapters as a session read serves them: nil from a conversation that never had any.
    func chaptersSnapshot() -> (chapters: [Chapter]?, revision: Int?) {
        guard chaptersRevision > 0 || !chapters.isEmpty else { return (nil, nil) }
        return (ChapterBook.resolved(chapters, messages: snapshotMessages()), chaptersRevision)
    }

    func chapterRecord() -> (chapters: [Chapter]?, revision: Int?, titledAtTurn: Int?) {
        (chapters.isEmpty ? nil : chapters, chaptersRevision > 0 ? chaptersRevision : nil, titledAtTurn)
    }

    /// Puts back what the store kept, counted again against the messages as the transcript reads.
    func restoreChapters(_ restored: [Chapter], revision: Int, titledAtTurn turn: Int?) {
        chapters = ChapterBook.reanchored(restored, messages: messages)
        chaptersRevision = revision
        titledAtTurn = turn
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
                id: state.id, title: state.title ?? "agent", agentType: state.agentType,
                toolUseID: state.toolUseID, updatedAt: state.updatedAt, active: state.active,
                completed: !state.active, startedAt: state.startedAt, toolCount: state.toolCount,
                currentTool: state.currentTool)
        }
        .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
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
        engineStartedAt = Date()
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
        Task {
            await proc.request("set_subagent_subscription", fields: ["level": "progress"])
            await proc.request(
                "set_event_filter", fields: ["events": NSNull(), "messageUpdates": "delta"])
        }
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

    /// When the engine last did anything, for the reaper: nil when there is no engine to let go or
    /// the conversation still has work on it.
    func idleEngineSince() async -> Date? {
        guard let process, await process.isRunning, pendingUI == nil, !carriesWork() else {
            return nil
        }
        return max(lastEventAt, engineStartedAt)
    }

    /// Lets an idle engine go, unless the engine says background work (an async shell, task or
    /// eval) could still wake it, or anything touched the conversation after `since` was read: the
    /// engine is asked across an await, so everything is checked again on the step that stops it.
    /// The next prompt starts a fresh engine on the same transcript.
    func releaseIdleEngine(quietSince since: Date) async -> Bool {
        guard let engine = process, pendingUI == nil, !carriesWork() else { return false }
        let state = await engine.request("get_state", timeout: 10)
        guard state.success, state.data?["hasPendingAsyncWork"]?.boolValue != true,
            state.data?["isStreaming"]?.boolValue != true,
            process === engine, pendingUI == nil, !carriesWork(),
            max(lastEventAt, engineStartedAt) <= since
        else { return false }
        process = nil
        await engine.stop()
        return true
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
        if queuePaused {
            queuePaused = false
            await publishQueue()
        }

        if text.hasPrefix("/compact") {
            guard !compacting else {
                throw BridgeError.conflict("A compaction is already running")
            }
            let held = Self.held(
                id: UUID().uuidString, text: text, kind: QueuedItem.commandKind, model: nil,
                effort: nil, stored: [])
            if busy {
                await append(held)
                return (true, queue.count - 1)
            }
            starting = true
            Task { await self.launch(held) }
            return (false, nil)
        }

        if pendingUI != nil {
            await resolvePendingUI(with: shown ?? text)
            return (false, nil)
        }

        if busy {
            await append(
                Self.held(
                    id: UUID().uuidString, text: shown ?? text, kind: QueuedItem.promptKind,
                    model: wantModel, effort: wantEffort,
                    stored: files.map { StoredAttachment(file: $0, size: Self.size(of: $0)) }))
            return (true, queue.count - 1)
        }

        starting = true
        do {
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
            await echo(shown ?? text, files: files)
            try await startTurn(prompt: promptText, display: shown ?? text)
        } catch {
            starting = false
            await drainQueue()
            throw error
        }
        starting = false
        return (false, nil)
    }

    /// Puts the user's words in the conversation and on the wire. A queued message is not part of
    /// the conversation until it starts: the transcript only ever holds what the engine was sent.
    private func echo(_ display: String, files: [FileRef]) async {
        var userParts: [Part] = [.text(display)]
        userParts.append(contentsOf: files.map { Part.file($0) })
        let userMessage = Message(
            id: "u-\(UUID().uuidString.prefix(8))", role: .user,
            parts: userParts, createdAt: Date(), seconds: nil, model: nil, usage: nil,
            costUSD: nil)
        messages.append(userMessage)
        let prior = title
        titleFromFirstPrompt(display)
        touch()
        await publish(.messageUpserted(userMessage))
        if ChapterBook.recorded(
            &chapters, messages: messages, title: title, priorTitle: prior,
            namer: ChapterBook.openingNamer(customTitle: customTitle, scheduled: scheduleID != nil))
        {
            await publishChapters()
        }
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
            finishTurn(cause: .processFailure)
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
            finishTurn(cause: .processFailure)
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
        starting = false
        turnStartedAt = Date()
        noteTurnStarted(at: turnStartedAt ?? Date())
        turnPrompt = display
        turnCalls = 0
        turnTokens = TokenCounts()
        turnCost = 0
        turnHadContent = false
        turnLastErrorMessage = nil
        await quietRegistry.increment()
        await publish(.status("running"))
        let turnID = "t-\(UUID().uuidString.prefix(8))"
        journalTurnID = turnID
        await journal?.write(
            JournalEntry(
                turnID: turnID, sessionID: id,
                ompSessionFile: ompSessionFile, prompt: display, startedAt: Date(),
                pid: await proc.processID))
        let requestID = await proc.reserveRequestID()
        turnRequestID = requestID
        let response = await proc.request("prompt", fields: ["message": prompt], id: requestID)
        if !response.success, response.errorCode != "timeout", running {
            await publish(.error(response.error ?? "The prompt was refused"))
            finishTurn()
            return
        }
        if response.data?["agentInvoked"]?.boolValue == false, running, turnRequestID == requestID {
            finishLocalCommand()
        }
        await syncState(from: proc)
    }

    /// A slash command oh-my-pi answered by itself, without the model: it says so in the prompt's
    /// acknowledgement and sends no `prompt_result` and no `agent_end`, so nothing else would ever
    /// close the turn — it sat open until the silence healer gave up on it. What the command
    /// printed is already in the live message; it is closed as the answer and not counted as a
    /// model turn.
    private func finishLocalCommand() {
        turnStartedAt = nil
        finishTurn()
    }

    /// Text a local slash command printed. It lands in the open turn's answer the way the model's
    /// words would, so `/help` or `/usage` reads as a reply rather than as a turn that said nothing.
    private func appendCommandOutput(_ text: String) async {
        guard running, !text.isEmpty else { return }
        if liveMessageID == nil { await openLiveAnswer(model: liveModel) }
        guard let messageID = liveMessageID else { return }
        let chunk = Self.hasText(liveParts) ? "\n" + text : text
        appendToLiveText(chunk)
        turnHadContent = true
        await publish(.partTextDelta(messageID: messageID, delta: chunk))
    }

    private static func hasText(_ parts: [LivePart]) -> Bool {
        parts.contains { part in
            if case .text(let text) = part { return !text.isEmpty }
            return false
        }
    }

    /// The terminal word on a prompt, sent once after everything the prompt caused has settled. A
    /// turn the engine ended without a terminal `agent_end` — an abort for a manual compaction, a
    /// failure before the model was reached — is closed here at once instead of after the silence
    /// healer's twenty seconds and two probes. A prompt whose run yielded to background work it
    /// started (`sessionSettled: false`) is not over: the work will wake the engine again, and the
    /// turn stays open until the engine says the session has settled.
    private func settlePrompt(_ frame: JSONValue) async {
        guard running, let id = frame["id"]?.stringValue, id == turnRequestID else { return }
        switch frame["status"]?.stringValue {
        case "aborted":
            finishTurn(cause: .aborted)
        case "completed" where frame["sessionSettled"]?.boolValue == false:
            awaitingSettle = true
        case "error":
            let error = frame["error"]?["message"]?.stringValue
                ?? "The turn failed."
            if turnLastErrorMessage == nil { turnLastErrorMessage = error }
            if !turnHadContent { await publish(.error(error)) }
            finishTurn()
        default:
            finishTurn()
        }
    }

    /// oh-my-pi's own retry of a failed request: the attempt, how long it waits, and the provider's
    /// words for what failed.
    private func beginRetry(_ frame: JSONValue) async {
        guard running else { return }
        let delay = frame["delayMs"]?.doubleValue
        let wait = RetryWait(
            attempt: max(1, frame["attempt"]?.intValue ?? 1),
            maxRetries: frame["maxAttempts"]?.intValue,
            reason: Self.firstLine(frame["errorMessage"]?.stringValue)
                ?? "A request to the provider failed",
            status: nil,
            nextAttemptAt: delay.map { Date().addingTimeInterval(max(0, $0) / 1000) })
        retryWait = wait
        await publish(.retry(wait))
    }

    private func endRetry() async {
        guard retryWait != nil else { return }
        retryWait = nil
        await publish(.retry(nil))
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
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

    /// Ends the running turn and holds the queue back: Stop means stop, and leaving the queue to
    /// drain would start a fresh turn the moment the one just killed ended. What people queued is
    /// theirs to cancel, so the items stay until a new message, an enqueue or a resume.
    func abort() async -> (stopped: Bool, paused: Bool) {
        let shouldPause = running || !queue.isEmpty
        let newlyPaused = shouldPause && !queuePaused
        if shouldPause { queuePaused = true }
        if newlyPaused { await publishQueue() }
        guard running, let process else { return (false, newlyPaused) }
        let stopping = turnStartedAt
        _ = await process.request("abort")
        if turnStartedAt == stopping { finishTurn(cause: .aborted) }
        return (true, newlyPaused)
    }

    /// Empties the conversation and puts the engine on a fresh transcript, so the model forgets
    /// what was cleared and the old rows are never read back in: emptying only the bridge's copy
    /// left the engine holding the whole context and the next sweep re-adopting the transcript.
    /// Without an engine, the next one simply starts fresh. Answers the transcript left behind,
    /// for the caller to hide from the list. What comes next is named afresh, and the chapters go
    /// with what they told. A prompt sent meanwhile waits in the queue and goes once it is done.
    @discardableResult
    func clear() async throws -> String? {
        guard !busy, queue.isEmpty else {
            throw BridgeError.conflict(
                "This session has a turn running. Stop it first, or fork to start clean without interrupting it.")
        }
        let retired = ompSessionID
        starting = true
        do {
            try await startAfresh()
        } catch {
            starting = false
            await drainQueue()
            throw error
        }
        starting = false
        lastTranscriptMtime = nil
        transcriptBehind = false
        transcriptActivity = TranscriptActivity()
        externallyLive = false
        if !subagents.isEmpty {
            subagents.removeAll()
            await publishAgents()
        }
        messages.removeAll()
        turns.removeAll()
        totalCostUSD = 0
        totalTokens = TokenCounts()
        conversationEpoch += 1
        autoTitled = false
        titledAtTurn = nil
        let hadChapters = !chapters.isEmpty
        chapters = []
        touch()
        if hadChapters { await publishChapters() }
        await drainQueue()
        return retired
    }

    private func startAfresh() async throws {
        guard let engine = process, await engine.isRunning else {
            ompSessionFile = nil
            ompSessionID = nil
            return
        }
        let fresh = await engine.request("new_session", timeout: 30)
        guard fresh.success, fresh.data?["cancelled"]?.boolValue != true else {
            throw BridgeError.conflict(
                "oh-my-pi would not start the conversation afresh: \(fresh.error ?? "it declined")")
        }
        if !model.isEmpty { await applyModelOn(engine, model) }
        if !effort.isEmpty {
            _ = await engine.request("set_thinking_level", fields: ["level": effort])
        }
        await syncState(from: engine)
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
        starting = false
        let startedAt = Date()
        compactionStartedAt = startedAt
        await holdQuietForCompaction()
        await publish(.compaction(phase: "started", error: nil))
        var fields: [String: any Sendable] = [:]
        if let instructions, !instructions.isEmpty { fields["customInstructions"] = instructions }
        let response = await proc.request("compact", fields: fields, timeout: 900)
        compacting = false
        compactionStartedAt = nil
        await releaseQuietForCompaction()
        if response.success {
            await recordCompaction(trigger: "manual", result: response.data, startedAt: startedAt)
            await publish(.compaction(phase: "finished", error: nil))
        } else {
            await publish(.compaction(phase: "failed", error: response.error))
        }
        await drainQueue()
    }

    /// Whether this conversation's compaction is counted in the machine's quiet registry. A
    /// compaction can end three ways (its answer, oh-my-pi's own end frame, the engine dying), and
    /// counting it once and uncounting it once, whichever comes first, keeps the registry from
    /// reading quiet while another conversation's turn runs and an update restarts under it.
    private var quietHeldForCompaction = false

    private func holdQuietForCompaction() async {
        guard !quietHeldForCompaction else { return }
        quietHeldForCompaction = true
        await quietRegistry.increment()
    }

    private func releaseQuietForCompaction() async {
        guard quietHeldForCompaction else { return }
        quietHeldForCompaction = false
        await quietRegistry.decrement()
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

    /// Starts the head of the queue when nothing is running or about to run and nothing holds the
    /// queue back. Asked at every point a turn or a compaction can end.
    private func drainQueue() async {
        guard !busy, !queuePaused, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        starting = true
        rememberStarted(next.item.id)
        await publishQueue()
        await launch(next)
    }

    /// Runs an item that has left the queue, or that was accepted with the queue empty. The caller
    /// has already set ``starting``. A compaction opens no transcript row of its own; anything else
    /// is written into the conversation here, the moment it is sent, and gets the model and effort
    /// it was queued with.
    private func launch(_ held: HeldQueueItem) async {
        defer { starting = false }
        let text = held.item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if text.hasPrefix("/compact") {
                let instructions =
                    text.dropFirst("/compact".count).trimmingCharacters(in: .whitespacesAndNewlines)
                try await startCompaction(instructions: instructions.isEmpty ? nil : instructions)
                return
            }
            if let wantEffort = held.item.effort, wantEffort != effort {
                effort = wantEffort
                let proc = try await ensureProcess()
                _ = await proc.request("set_thinking_level", fields: ["level": wantEffort])
            }
            if let wantModel = held.item.model, wantModel != model, !wantModel.isEmpty {
                let proc = try await ensureProcess()
                if await applyModelOn(proc, wantModel) {
                    model = wantModel
                } else {
                    await publish(
                        .error("This machine's oh-my-pi has no model called \(wantModel); staying on \(model)"))
                }
            }
            await echo(held.item.text, files: held.files)
            try await startTurn(prompt: Self.prompt(text, files: held.files), display: held.item.text)
        } catch {
            await publish(.error(error.localizedDescription))
            await holdQueueAfterFailedLaunch()
        }
    }

    /// A launch that failed (the engine would not start, say) ends no turn, so nothing would ever
    /// drain what is queued behind it: the items sat there unpaused and a direct send jumped ahead
    /// of them. They are held as paused instead, which every client shows, and a resume or the
    /// next send tries again.
    private func holdQueueAfterFailedLaunch() async {
        guard !queue.isEmpty, !queuePaused else { return }
        queuePaused = true
        await publishQueue()
    }

    // MARK: shared queue

    /// What a client draws: the items waiting, in arrival order, and whether draining is held back.
    func queueSnapshot() -> QueueSnapshot {
        QueueSnapshot(queue: queue.map(\.item), paused: queuePaused)
    }

    /// The snapshot a new subscriber is greeted with, or `nil` when there is nothing to say.
    func queueGreeting() -> QueueSnapshot? {
        let snapshot = queueSnapshot()
        return snapshot.queue.isEmpty && !snapshot.paused ? nil : snapshot
    }

    /// Tells subscribers a queue that came back from disk is there, and paused. Run once the
    /// session is registered, so the bridge-wide stream hears it too.
    func announceRestoredQueue() async {
        guard queueRestored else { return }
        queueRestored = false
        await publish(.queue(queueSnapshot()))
    }

    private var busy: Bool { running || compacting || starting }

    private func persistQueue() {
        QueueFile.write(
            queue.isEmpty ? nil : PersistedQueue(items: queue, paused: queuePaused), to: queueURL)
    }

    /// Writes the queue to disk and tells every client what it now holds.
    private func publishQueue() async {
        persistQueue()
        await publish(.queue(queueSnapshot()))
    }

    private func append(_ held: HeldQueueItem) async {
        queue.append(held)
        await publishQueue()
    }

    private static let startedMemory = 64

    private func rememberStarted(_ itemID: String) {
        startedQueueIDs.append(itemID)
        startedQueueIDs = Array(startedQueueIDs.suffix(Self.startedMemory))
    }

    static func held(
        id: String, text: String, kind: String, model: String?, effort: String?,
        stored: [StoredAttachment]
    ) -> HeldQueueItem {
        HeldQueueItem(
            item: QueuedItem(
                id: id, text: text, kind: kind, model: model, effort: effort,
                attachments: stored.map {
                    QueueAttachment(
                        mime: $0.file.mime, filename: $0.file.filename ?? "", size: $0.size)
                },
                createdAt: Date()),
            files: stored.map(\.file))
    }

    private static func size(of file: FileRef) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) ?? 0
    }

    /// The prompt the engine is handed: the words, then where each attached file is so the Read
    /// tool can open it.
    static func prompt(_ text: String, files: [FileRef]) -> String {
        guard !files.isEmpty else { return text }
        let lines = files.map { "Attached image (use the Read tool to view it): \($0.path)" }
        return ([text] + lines).joined(separator: "\n")
    }

    /// Queues a message behind the running turn, or starts it at once when nothing is running.
    /// Idempotent on the client's id: an item already queued, or one that already started, is
    /// answered with the current snapshot and changes nothing.
    func enqueue(_ request: EnqueueRequest) async -> EnqueueOutcome {
        if running { await healDeadTurn() }
        let itemID = request.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else { return .invalid("An item needs an id.") }
        let kind = request.kind ?? QueuedItem.promptKind
        guard kind == QueuedItem.promptKind || kind == QueuedItem.commandKind else {
            return .invalid("kind is prompt or command.")
        }
        if queue.contains(where: { $0.item.id == itemID }) {
            return .accepted(started: false, snapshot: queueSnapshot())
        }
        if startedQueueIDs.contains(itemID) {
            return .accepted(started: true, snapshot: queueSnapshot())
        }
        let attachments = request.attachments ?? []
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
        else { return .invalid("An item needs text or an attachment.") }
        let held = Self.held(
            id: itemID, text: request.text, kind: kind, model: request.model,
            effort: request.effort,
            stored: AttachmentStore.save(
                attachments, sessionID: id, directory: config.attachmentsDir))
        let wasPaused = queuePaused
        queuePaused = false
        if !busy, queue.isEmpty {
            starting = true
            rememberStarted(itemID)
            if wasPaused { await publishQueue() }
            await launch(held)
            return .accepted(started: true, snapshot: queueSnapshot())
        }
        await append(held)
        await drainQueue()
        return .accepted(started: false, snapshot: queueSnapshot())
    }

    /// Changes a queued item's words, model or effort. An item that has started, or is gone, can
    /// no longer be changed.
    func editQueued(_ itemID: String, request: EditQueuedRequest) async -> QueueChangeOutcome {
        guard let index = queue.firstIndex(where: { $0.item.id == itemID }) else {
            return .alreadyStarted
        }
        if let text = request.text { queue[index].item.text = text }
        if let model = request.model { queue[index].item.model = model.isEmpty ? nil : model }
        if let effort = request.effort { queue[index].item.effort = effort.isEmpty ? nil : effort }
        await publishQueue()
        return .changed(queueSnapshot())
    }

    /// Takes an item out of the queue. Cancelling what is already gone is fine, so a retry is
    /// safe; cancelling what has started is not.
    func cancelQueued(_ itemID: String) async -> QueueChangeOutcome {
        guard let index = queue.firstIndex(where: { $0.item.id == itemID }) else {
            return startedQueueIDs.contains(itemID) ? .alreadyStarted : .changed(queueSnapshot())
        }
        let removed = queue.remove(at: index)
        for file in removed.files { try? FileManager.default.removeItem(atPath: file.path) }
        await publishQueue()
        return .changed(queueSnapshot())
    }

    /// Lets a held queue run again, starting its head when nothing is running.
    func resumeQueue() async -> QueueSnapshot {
        if queuePaused {
            queuePaused = false
            await publishQueue()
        }
        await drainQueue()
        return queueSnapshot()
    }

    /// A deleted conversation takes its queue, and the files kept for it, with it.
    func discardQueue() {
        for held in queue {
            for file in held.files { try? FileManager.default.removeItem(atPath: file.path) }
        }
        queue = []
        QueueFile.write(nil, to: queueURL)
    }

    private func finishTurn(cause: TurnEndCause = .agentEnd) {
        guard running else { return }
        running = false
        turnRequestID = nil
        awaitingSettle = false
        toolPublishedAt = [:]
        let waited = retryWait != nil
        retryWait = nil
        settleOwnTurn()
        var unfinished = closeLiveMessage()
        let answer = (unfinished ?? messages.last { $0.role == .assistant }).map(Self.plainText) ?? ""
        let failed = cause == .processFailure || turnLastErrorMessage != nil
        let quiet = quietPending && !failed && cause != .aborted
            && ScheduleWording.saysNothingNew(answer)
        quietPending = false
        if quiet, let last = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[last].parts = [.text(ScheduleWording.nothingNewLine)]
            if unfinished?.id == messages[last].id { unfinished = messages[last] }
        }
        TurnEnds.shared.tell(
            id,
            TurnEndNote(
                answer: answer,
                failure: failed ? (turnLastErrorMessage ?? "The turn failed.") : nil,
                stopped: cause == .aborted, quiet: quiet))
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
        recordTurnOutcome(cause: cause, unfinished: unfinished)
        turnStartedAt = nil
        settleUnansweredAsk()
        let settled = settleDanglingTools()
        autoTitleIfUnnamed()
        let finishedTurnID = journalTurnID
        journalTurnID = nil
        Task {
            if waited { await publish(.retry(nil)) }
            if let unfinished { await publish(.messageUpserted(unfinished)) }
            for message in settled where message.id != unfinished?.id {
                await publish(.messageUpserted(message))
            }
            if !running { await publish(.status("idle")) }
            if let finishedTurnID { await journal?.clear(id, turnID: finishedTurnID) }
            await quietRegistry.decrement()
            await drainQueue()
        }
    }

    /// What a waiting client is told once this turn is over. Recorded here because nothing later
    /// remembers it: ``turnStartedAt`` and the turn counters below are cleared for the next turn
    /// the moment this call returns.
    private func recordTurnOutcome(cause: TurnEndCause, unfinished: Message?) {
        endedCarrying = activeAgentCount > 0 || (!queuePaused && !queue.isEmpty)
        let duration = turnStartedAt.map { Date().timeIntervalSince($0) }
        lastTurnOutcome = TurnOutcome(
            ending: Self.turnEnding(
                cause: cause, turnHadContent: turnHadContent,
                hasError: turnLastErrorMessage != nil),
            toolCount: turnStartedAt != nil ? turnCalls : nil,
            duration: duration, lastMessageID: unfinished?.id ?? messages.last?.id,
            endedAt: Date())
    }

    /// omp never says why a turn stopped beyond what it hands the engine's own frames — a cause
    /// this bridge caused itself (``aborted``) or observed itself (``processFailure``) is never
    /// ambiguous, but an ordinary `agent_end` still has to be read against whether anything was
    /// said and whether the last message carried an error.
    private static func turnEnding(cause: TurnEndCause, turnHadContent: Bool, hasError: Bool)
        -> TurnWait.Ending
    {
        switch cause {
        case .aborted: return .cancelled
        case .processFailure: return .failed
        case .agentEnd: return hasError ? .failed : (turnHadContent ? .finished : .answerless)
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

    /// The provider's reason an answer failed, when it did: an `error` stop with its message. An
    /// abort is the person's Stop, not a failure, and says nothing here.
    static func failure(of message: JSONValue) -> String? {
        guard message["stopReason"]?.stringValue == "error",
            let reason = message["errorMessage"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !reason.isEmpty
        else { return nil }
        return reason
    }

    /// Puts a failure on the answer it ended, or — when the turn failed before it said anything —
    /// on an answer of its own, so the conversation keeps the failed turn rather than a prompt left
    /// hanging.
    private func keepFailure(_ reason: String, on assembled: Message?) -> Message {
        if let assembled, let index = messages.lastIndex(where: { $0.id == assembled.id }) {
            messages[index].error = reason
            return messages[index]
        }
        let failed = Message(
            id: "a-\(UUID().uuidString.prefix(8))", role: .assistant, parts: [], createdAt: Date(),
            seconds: turnStartedAt.map { Date().timeIntervalSince($0) }, model: liveModel,
            usage: nil, context: nil, costUSD: nil, error: reason)
        messages.append(failed)
        touch()
        return failed
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
        case "cancel":
            guard let target = frame["targetId"]?.stringValue, pendingUI?.requestID == target else { return }
            settleUnansweredAsk()
        case "select", "confirm", "input", "editor":
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
                await releaseQuietForCompaction()
                await publish(.compaction(phase: "failed", error: "The oh-my-pi process exited"))
            }
            if running {
                await publish(.error("The oh-my-pi process exited before the turn ended."))
                finishTurn(cause: .processFailure)
            }
        case "agent_start":
            if !running {
                running = true
                await quietRegistry.increment()
            }
            if turnStartedAt == nil {
                turnStartedAt = Date()
                noteTurnStarted(at: turnStartedAt ?? Date())
            }
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
                await holdQuietForCompaction()
                await publish(.compaction(phase: "started", error: nil))
            }
        case "auto_compaction_end":
            if frame["skipped"]?.boolValue == true { break }
            compacting = false
            let startedAt = compactionStartedAt ?? Date()
            compactionStartedAt = nil
            await releaseQuietForCompaction()
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
            if frame["level"]?.stringValue == "error", let message = frame["message"]?.stringValue {
                await publish(.error(message))
            }
        case "available_commands_update":
            knownCommands = CommandCatalog.parse(frame["commands"]?.arrayValue ?? [])
        case "subagent_lifecycle", "subagent_progress":
            await recordSubagentFrame(frame, type: type)
        case "prompt_result":
            await settlePrompt(frame)
        case "session_settled":
            if running, awaitingSettle { finishTurn() }
        case "command_output":
            await appendCommandOutput(frame["text"]?.stringValue ?? "")
        case "auto_retry_start":
            await beginRetry(frame)
        case "auto_retry_end":
            await endRetry()
        case "config_update":
            if let model = Self.qualifiedModel(inState: frame), !model.isEmpty { self.model = model }
            if let level = frame["thinkingLevel"]?.stringValue { effort = level }
        case "thinking_level_changed":
            if let level = frame["thinkingLevel"]?.stringValue { effort = level }
        case "agent_end":
            let terminal = frame["isTerminal"]?.boolValue ?? true
            if terminal {
                await settleTurnEnd()
            }
        default:
            break
        }
    }

    /// Keeps the agents still at work and the most recent finished ones: every agents frame
    /// carries the whole list, sorted, and a long chat would otherwise send every sub-agent it
    /// ever ran on every change for the rest of its life.
    private func forgetOldFinishedAgents() {
        let finished = subagents.values.filter { !$0.active }
        guard finished.count > Self.finishedAgentsKept else { return }
        for state in finished.sorted(by: { $0.updatedAt > $1.updatedAt }).dropFirst(Self.finishedAgentsKept) {
            subagents.removeValue(forKey: state.id)
        }
    }

    private static let finishedAgentsKept = 50

    /// oh-my-pi's word on a sub-agent, which lives under `payload`: a lifecycle frame when one
    /// starts or ends, and a progress frame — keyed by the same id inside `progress` — whenever its
    /// tool count or current tool moves. Reading the frame's top level, as this once did, found
    /// nothing and left every omp chat with no agents at all.
    private func recordSubagentFrame(_ frame: JSONValue, type: String) async {
        guard let payload = frame["payload"] else { return }
        let progress = payload["progress"]
        guard let agentID = payload["id"]?.stringValue ?? progress?["id"]?.stringValue else { return }
        let now = Date()
        let known = subagents[agentID]
        var state = known ?? SubagentState(id: agentID, title: nil, active: true, updatedAt: now)
        state.agentType = payload["agent"]?.stringValue ?? state.agentType
        state.toolUseID = payload["parentToolCallId"]?.stringValue ?? state.toolUseID
        if let description = payload["description"]?.stringValue ?? progress?["description"]?.stringValue
            ?? payload["task"]?.stringValue, !description.isEmpty
        {
            state.title = description
        }
        let status = (type == "subagent_lifecycle" ? payload["status"] : progress?["status"])?.stringValue
        switch status {
        case "completed", "failed", "aborted":
            state.active = false
            state.currentTool = nil
        case "started", "running", "pending":
            state.active = true
        default:
            break
        }
        if state.startedAt == nil { state.startedAt = now }
        if let progress {
            state.toolCount = progress["toolCount"]?.intValue ?? state.toolCount
            if state.active {
                state.currentTool = progress["currentTool"]?.stringValue ?? progress["lastIntent"]?.stringValue
            }
        }
        state.updatedAt = now
        subagents[agentID] = state
        if !state.active { forgetOldFinishedAgents() }
        let lifecycleMoved = known?.active != state.active
        let waited = now.timeIntervalSince(lastAgentsPublishAt)
        guard lifecycleMoved || waited >= Self.agentsFrameGap else {
            scheduleAgentsFrame(after: Self.agentsFrameGap - waited)
            return
        }
        await publishAgents()
    }

    /// A change held back by the one-a-second gate still goes out when the gap is up: the engine
    /// reports progress only when something happens, so a held frame might otherwise be the last
    /// word on an agent for as long as its next tool runs.
    private func scheduleAgentsFrame(after delay: TimeInterval) {
        guard agentsPublishTask == nil else { return }
        agentsPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            await self?.publishAgents()
        }
    }

    private func publishAgents() async {
        agentsPublishTask?.cancel()
        agentsPublishTask = nil
        lastAgentsPublishAt = Date()
        await hub.publish(.agents(sessionID: id, agents: subagentSummaries()))
    }

    /// How often a working sub-agent's progress is passed on. A start or an end goes at once.
    private static let agentsFrameGap: TimeInterval = 1

    private func handleMessageStart(_ frame: JSONValue) async {
        guard let message = frame["message"], let role = message["role"]?.stringValue else { return }
        switch role {
        case "assistant":
            await endRetry()
            await openLiveAnswer(model: TranscriptLoader.qualifiedModel(in: message) ?? liveModel)
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

    /// A new answer. One still open — what a slash command printed before it started a model run
    /// of its own — is closed first, so it lands in the transcript instead of being dropped.
    private func openLiveAnswer(model: String?) async {
        if liveMessageID != nil, let closed = closeLiveMessage() {
            await publish(.messageUpserted(closed))
        }
        liveMessageID = "a-\(UUID().uuidString.prefix(8))"
        liveCreatedAt = Date()
        liveParts = []
        pendingContentIndexes = [:]
        liveUsage = TokenCounts()
        liveContext = nil
        liveCost = 0
        liveModel = model
        lastSnapshotAt = .distantPast
        if let id = liveMessageID, let created = liveCreatedAt {
            await publish(
                .messageUpserted(
                    Message(
                        id: id, role: .assistant, parts: [.text("")], createdAt: created,
                        seconds: nil, model: liveModel, usage: nil, costUSD: nil)))
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
            let failure = Self.failure(of: message)
            var assembled = closeLiveMessage()
            if let failure {
                turnLastErrorMessage = failure
                assembled = keepFailure(failure, on: assembled)
            }
            if let assembled {
                await publish(.messageUpserted(assembled))
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
        guard let seat = seatOfToolPart(toolCallID) else { return }
        mutateToolPart(seat) { tool in
            tool.output = Self.boundedOutput(output)
        }
        let now = Date()
        guard now.timeIntervalSince(toolPublishedAt[toolCallID] ?? .distantPast) >= Self.toolOutputGap
        else { return }
        toolPublishedAt[toolCallID] = now
        await publishTool(seat)
    }

    /// How often a running tool's growing output is sent on. The end of the call always goes.
    private static let toolOutputGap: TimeInterval = 0.25
    private static let outputLimit = 10_000
    private static let outputHead = 4_000

    /// A tool's output cut to what a card can hold: its start, which says what ran, and its end,
    /// which says how it went — a build's errors, a test run's verdict. Keeping only the start
    /// froze a long command's live output at its first screen and dropped every final result's tail.
    static func boundedOutput(_ output: String) -> String {
        guard output.count > outputLimit else { return output }
        let tail = outputLimit - outputHead
        let elided = output.count - outputLimit
        return String(output.prefix(outputHead)) + "\n… \(elided) characters left out …\n"
            + String(output.suffix(tail))
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
        toolPublishedAt[toolCallID] = nil
        mutateToolPart(seat) { tool in
            tool.status = isError ? .error : .completed
            tool.output = Self.boundedOutput(output)
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
        if !chapters.isEmpty { chapters = ChapterBook.reanchored(chapters, messages: messages) }
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
        guard !busy, let file = ompSessionFile else {
            externallyLive = false
            return
        }
        let mtime = TranscriptLoader.mtime(file)
        if mtime != lastTranscriptMtime {
            lastTranscriptMtime = mtime
            let activity = TranscriptClock.read(atPath: file)
            if transcriptActivity.turnOpen, !activity.turnOpen { lastTranscriptLoadAt = .distantPast }
            transcriptActivity = activity
            if let said = activity.lastSaid, said > updatedAt { updatedAt = said }
            transcriptBehind = true
        }
        if transcriptBehind, Date().timeIntervalSince(lastTranscriptLoadAt) >= Self.transcriptReloadGap {
            transcriptBehind = false
            lastTranscriptLoadAt = Date()
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

    /// Told once by the app's own recovery pass, for a turn whose journal entry outlived the
    /// process that opened it: the bridge itself restarted or crashed mid-turn, so nothing here
    /// ever ran ``finishTurn(cause:)`` for it and the ending has to be written directly from what
    /// the journal and the recovered transcript still know.
    func markInterrupted(toolCount: Int, endedAt: Date) {
        lastTurnOutcome = TurnOutcome(
            ending: .interrupted, toolCount: toolCount > 0 ? toolCount : nil,
            duration: nil, lastMessageID: messages.last?.id, endedAt: endedAt)
    }

    func sessionFile() -> String? { ompSessionFile }
}
