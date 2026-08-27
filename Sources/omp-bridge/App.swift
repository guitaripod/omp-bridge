import Foundation

enum BridgeError: Error, LocalizedError {
    case badRequest(String)
    case notFound(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .badRequest(let message), .notFound(let message), .conflict(let message):
            return message
        }
    }
}

actor App {
    let config: Config
    let hub: Hub
    let store: SessionStore
    let quietRegistry: QuietRegistry
    let authFlow: AuthFlow
    let updateService: UpdateService

    private var sessions: [String: OmpSession] = [:]
    private let journal: TurnJournal
    private var lastSummaries: [String: SessionSummary] = [:]
    private var version = "unknown"
    private var interruptedBySession: [String: Interruption] = [:]
    private var ownedTranscriptsBySession: [String: Set<String>] = [:]
    private let discoveryCache = DiscoveryCache()
    private var lastStoredAt: [String: Date] = [:]

    init(config: Config) {
        self.config = config
        self.hub = Hub()
        self.store = SessionStore(path: config.storePath)
        self.quietRegistry = QuietRegistry()
        self.authFlow = AuthFlow(config: config)
        self.updateService = UpdateService(
            stateDirectory: URL(fileURLWithPath: config.stateDir),
            sourceOverride: config.srcPath)
        self.journal = TurnJournal(path: config.stateDir + "/turns.json")
        self.version = "unknown"
    }

    func prepare() async {
        if let source = config.srcPath {
            let described = Shell.run("git", ["describe", "--tags", "--always", "--dirty"], cwd: source)
            if !described.isEmpty { version = described.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        await restorePersistedSessions()
        await recoverInterruptedTurns()
    }

    // MARK: sessions

    func createSession(
        title: String?, directory: String?, model: String?, effort: String?
    ) -> OmpSession {
        let dir = directory.map { NSString(string: $0).expandingTildeInPath } ?? config.workdir
        var isDirectory: ObjCBool = false
        let resolved =
            FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
            && isDirectory.boolValue ? dir : config.workdir
        let session = OmpSession(
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "New chat",
            directory: resolved,
            model: model.flatMap { $0.isEmpty ? nil : $0 } ?? config.defaultModel ?? "",
            effort: effort ?? config.defaultEffort,
            config: config, hub: hub, quietRegistry: quietRegistry, journal: journal)
        sessions[session.id] = session
        return session
    }

    func liveSession(id: String) -> OmpSession? { sessions[id] }

    func liveSessionIDs() -> [String] { Array(sessions.keys) }

    func knowsSession(id: String) -> Bool { sessions[id] != nil }

    func adoptDiscovered(id wanted: String) async -> OmpSession? {
        if let live = await sessionOwning(transcriptID: wanted) { return live }
        let claimedFiles = await claimedFiles()
        let hidden = await store.hiddenList()
        let found = Discovery.scan(
            root: config.ompSessionsRoot, hidden: hidden, claimedFiles: claimedFiles,
            cache: discoveryCache)
        let match = found.first(where: { $0.ompSessionID == wanted })
        guard let match, match.directory.map({ !Discovery.isJunkDirectory($0) }) ?? true else {
            return nil
        }
        return await adopt(file: match.file, ompID: match.ompSessionID)
    }

    /// The live session that already answers for this bridge id, omp session id, or transcript
    /// file, if any. Adoption MUST consult this first: the App actor is reentrant, and a client
    /// opening a chat fires several requests at once — without the lookup each one adopts the same
    /// transcript under a fresh UUID and the list grows a twin.
    private func sessionOwning(transcriptID: String? = nil, file: String? = nil) async -> OmpSession? {
        if let transcriptID {
            if let live = sessions[transcriptID] { return live }
            for (id, owned) in ownedTranscriptsBySession where owned.contains(transcriptID) {
                if let live = sessions[id] { return live }
            }
            for (_, session) in sessions where await session.currentOmpSessionID() == transcriptID {
                return session
            }
        }
        if let file {
            for (_, session) in sessions where await session.sessionFile() == file {
                return session
            }
        }
        return nil
    }

    private var adoptionsInFlight: [String: Task<OmpSession, Never>] = [:]

    func adopt(file: String, ompID: String?) async -> OmpSession {
        if let existing = await sessionOwning(transcriptID: ompID, file: file) { return existing }
        if let inFlight = adoptionsInFlight[file] { return await inFlight.value }
        let task = Task { [config, hub, quietRegistry, journal] in
            let adopted = TranscriptLoader.load(sessionFile: file)
            let session = OmpSession(
                title: adopted.title ?? OmpSession.derivedTitle(from: adopted.firstUserText ?? "Session"),
                directory: adopted.cwd ?? config.workdir,
                model: config.defaultModel ?? "",
                effort: config.defaultEffort,
                ompSessionFile: file, config: config, hub: hub, quietRegistry: quietRegistry,
                journal: journal)
            await session.adoptExternally(loaded: adopted, ompID: ompID)
            return session
        }
        adoptionsInFlight[file] = task
        let session = await task.value
        adoptionsInFlight.removeValue(forKey: file)
        if let existing = await sessionOwning(transcriptID: ompID, file: file) { return existing }
        sessions[session.id] = session
        ownedTranscriptsBySession[session.id] = Set(await session.ownedTranscriptIDs())
        await store.upsert(await record(for: session))
        return session
    }

    func deleteSession(id: String) async {
        if let session = sessions.removeValue(forKey: id) {
            await session.shutdown()
            ownedTranscriptsBySession.removeValue(forKey: id)
            _ = await store.remove(id)
        } else {
            _ = await store.remove(id)
        }
        lastSummaries.removeValue(forKey: id)
        lastStoredAt.removeValue(forKey: id)
        await hub.publish(.listRemove(id: id))
    }

    func forkSession(id: String) async throws -> OmpSession {
        guard let source = sessions[id] else { throw BridgeError.notFound("not found") }
        let forkDirectory = config.stateDir + "/forks"
        try? FileManager.default.createDirectory(atPath: forkDirectory, withIntermediateDirectories: true)
        let copyPath = forkDirectory + "/\(UUID().uuidString).jsonl"
        let sourceFile = await source.sessionFile()
        if let file = sourceFile, FileManager.default.fileExists(atPath: file) {
            try? FileManager.default.copyItem(atPath: file, toPath: copyPath)
        }
        let session = OmpSession(
            title: (await source.titleText()) + " (fork)",
            directory: await source.directoryPath(),
            model: await source.modelName(),
            effort: await source.effortLevel(),
            ompSessionFile: FileManager.default.fileExists(atPath: copyPath) ? copyPath : nil,
            config: config, hub: hub, quietRegistry: quietRegistry, journal: journal)
        if FileManager.default.fileExists(atPath: copyPath) {
            let loaded = TranscriptLoader.load(sessionFile: copyPath)
            await session.adoptExternally(loaded: loaded, ompID: nil)
        }
        sessions[session.id] = session
        return session
    }

    // MARK: listing / observer

    func currentSummaries() async -> [String: SessionSummary] {
        var byID: [String: SessionSummary] = [:]
        for (_, session) in sessions {
            byID[session.id] = await session.summarySnapshot()
        }
        let claimedFiles = await claimedFiles()
        let hidden = await hiddenIDs()
        let discovered = Discovery.scan(
            root: config.ompSessionsRoot, hidden: hidden, claimedFiles: claimedFiles,
            cache: discoveryCache)
        let claimedIDs = Set(ownedTranscriptsBySession.values.flatMap { $0 })
        for item in discovered where !claimedIDs.contains(item.ompSessionID) {
            byID[item.ompSessionID] = SessionSummary(
                id: item.ompSessionID, title: item.title, directory: item.directory,
                model: "", effort: "", createdAt: item.updatedAt, updatedAt: item.updatedAt)
        }
        return byID
    }

    private func claimedFiles() async -> Set<String> {
        var files = Set<String>()
        for (_, session) in sessions {
            if let file = await session.sessionFile() { files.insert(file) }
        }
        return files
    }

    private func hiddenIDs() async -> [String] {
        await store.hiddenList()
    }

    func runObserver() async {
        while !Task.isCancelled {
            await sweep()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func sweep() async {
        let current = await currentSummaries()
        for (id, summary) in current where lastSummaries[id] != summary {
            await hub.publish(.listUpsert(summary))
        }
        for id in lastSummaries.keys where current[id] == nil {
            await hub.publish(.listRemove(id: id))
        }
        lastSummaries = current
        for (_, session) in sessions {
            await session.refreshFromTranscriptIfIdle()
            ownedTranscriptsBySession[session.id] = Set(await session.ownedTranscriptIDs())
            let updatedAt = await session.updatedDate()
            guard lastStoredAt[session.id] != updatedAt else { continue }
            lastStoredAt[session.id] = updatedAt
            await store.upsert(await record(for: session))
        }
    }

    private func ownedTranscriptIDs(for session: OmpSession) -> [String]? {
        guard let ids = ownedTranscriptsBySession[session.id], !ids.isEmpty else { return nil }
        return ids.sorted()
    }

    private func record(for session: OmpSession) async -> SessionRecord {
        SessionRecord(
            id: session.id,
            title: await session.titleText(),
            directory: await session.directoryPath(),
            model: await session.modelName(),
            effort: await session.effortLevel(),
            createdAt: await session.createdDate(),
            updatedAt: await session.updatedDate(),
            ompSessionID: await session.currentOmpSessionID(),
            ompSessionFile: await session.sessionFile(),
            customTitle: await session.customTitleValue(),
            autoTitled: await session.autoTitledValue(),
            turns: await session.turnsSnapshot(),
            totalCostUSD: await session.spendTotalsSnapshot().costUSD,
            totalTokens: await session.spendTotalsSnapshot().tokens,
            lastCostUSD: await session.turnsSnapshot().last?.costUSD,
            lastTokens: await session.turnsSnapshot().last?.tokens.total,
            interruption: interruptedBySession[session.id],
            autoResume: nil,
            ownedTranscriptIDs: ownedTranscriptIDs(for: session))
    }

    func flushAll() async {
        for (_, session) in sessions {
            await store.upsert(await record(for: session))
        }
        await store.flush()
    }

    // MARK: interruptions
    /// Restores the store, keeping exactly one session per transcript file: earlier builds could
    /// adopt the same transcript twice under different UUIDs, and a store carrying such twins would
    /// re-grow the doubled row on every launch. The newest record wins; the losers are removed for
    /// good, not hidden, so the survivor keeps answering for the transcript.
    private func restorePersistedSessions() async {
        var ownerByFile: [String: SessionRecord] = [:]
        var twins: [SessionRecord] = []
        for record in await store.allRecords().sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard let file = record.ompSessionFile else { continue }
            if ownerByFile[file] == nil {
                ownerByFile[file] = record
            } else {
                twins.append(record)
            }
        }
        for twin in twins {
            _ = await store.removeWithoutHiding(twin.id)
        }
        for record in await store.allRecords() {
            guard sessions[record.id] == nil else { continue }
            guard let file = record.ompSessionFile,
                FileManager.default.fileExists(atPath: file)
            else { continue }
            let session = OmpSession(
                id: record.id, title: record.title,
                directory: record.directory ?? config.workdir,
                model: record.model, effort: record.effort, ompSessionFile: file,
                config: config, hub: hub, quietRegistry: quietRegistry, journal: journal)
            await session.adoptExternally(loaded: TranscriptLoader.load(sessionFile: file), ompID: record.ompSessionID)
            sessions[record.id] = session
            ownedTranscriptsBySession[record.id] = Set(await session.ownedTranscriptIDs())
        }
    }

    private func recoverInterruptedTurns() async {
        for entry in await journal.interruptedEntries() {
            var progress = InterruptionProgress()
            if let file = entry.ompSessionFile {
                let loaded = TranscriptLoader.load(sessionFile: file)
                let duringTurn = loaded.messages.filter { $0.createdAt >= entry.startedAt }
                let toolParts = duringTurn.flatMap { message in
                    message.parts.compactMap { part -> ToolCall? in
                        if case .tool(let call) = part { return call }
                        return nil
                    }
                }
                progress.toolCount = toolParts.count
                progress.lastTool = toolParts.last?.name
                progress.partialAnswer = duringTurn.last(where: { $0.role == .assistant })
                    .flatMap { message in
                        message.parts.compactMap { part -> String? in
                            if case .text(let text) = part { return text }
                            return nil
                        }.first
                    }
                    .map { String($0.prefix(400)) }
            }
            let interruption = Interruption(
                turnID: entry.turnID, prompt: entry.prompt, startedAt: entry.startedAt,
                detectedAt: Date(), ompSessionFile: entry.ompSessionFile, progress: progress,
                queued: [], resumedAt: nil)
            interruptedBySession[entry.sessionID] = interruption
            if sessions[entry.sessionID] == nil, let file = entry.ompSessionFile,
                FileManager.default.fileExists(atPath: file)
            {
                _ = await adopt(file: file, ompID: nil)
            }
            await journal.clear(entry.sessionID)
            await hub.publish(.session(id: entry.sessionID, event: .interrupted(interruption)))
        }
    }

    func interruption(for id: String) -> Interruption? {
        interruptedBySession[id]
    }

    func dismissInterruption(id: String) async -> Bool {
        guard interruptedBySession[id] != nil else { return false }
        interruptedBySession.removeValue(forKey: id)
        await hub.publish(.session(id: id, event: .interrupted(nil)))
        return true
    }

    func resumeInterrupted(id: String) async throws {
        guard let interruption = interruptedBySession[id] else {
            throw BridgeError.conflict("Nothing interrupted to pick back up")
        }
        guard !interruption.isResumed else {
            throw BridgeError.conflict("This interrupted turn was already picked back up")
        }
        guard let session = sessions[id] else {
            throw BridgeError.notFound("not found")
        }
        interruptedBySession[id]?.resumedAt = Date()
        let continuation =
            "The previous turn was cut off before it finished. Here is what was asked; pick up where it left off:\n\n\(interruption.prompt)"
        _ = try await session.send(text: continuation, displayText: continuation, model: nil, effort: nil)
        interruptedBySession.removeValue(forKey: id)
        await hub.publish(.session(id: id, event: .interrupted(nil)))
    }

    // MARK: status / hub plumbing

    func statusPayload() async -> BridgeStatus {
        BridgeStatus(
            agent: "omp", model: config.defaultModel ?? "", version: version,
            authenticated: await authFlow.isAuthenticatedCached(), proto: 2,
            epoch: hub.epoch)
    }

    func hubEpoch() -> String { hub.epoch }

    func oldestReplayableSeqValue() async -> UInt64 {
        await hub.oldestReplayableSeq
    }

    func hubAttachment(sinceEpoch: String?, sinceSeq: UInt64?) async -> Hub.Attachment {
        await hub.attach(sinceEpoch: sinceEpoch, sinceSeq: sinceSeq)
    }

    func detachHub(id: UUID) async {
        await hub.detach(id)
    }

    func updateStatus(refreshing: Bool) async -> UpdateStatus {
        await updateService.status(refreshing: refreshing)
    }

    func startUpdate() async -> (accepted: Bool, status: UpdateStatus) {
        await updateService.start()
    }

    func restartUpdate() async -> (accepted: Bool, status: UpdateStatus) {
        await updateService.restart()
    }

    func runHeartbeats() async {
        await hub.runHeartbeats()
    }

    private var cachedModels: (fetchedAt: Date, models: [JSONValue])?
    private var failedModelsAt: Date?
    private var modelFetchTask: Task<[JSONValue], Never>?
    private var modelScratchProcess: OmpProcess?

    func modelCatalog() async -> [JSONValue] {
        if let cached = cachedModels, Date().timeIntervalSince(cached.fetchedAt) < 300 {
            return cached.models
        }
        if let failedAt = failedModelsAt, Date().timeIntervalSince(failedAt) < 60 {
            return cachedModels?.models ?? []
        }
        if let inFlight = modelFetchTask { return await inFlight.value }
        let task = Task { await self.fetchModelCatalog() }
        modelFetchTask = task
        let models = await task.value
        modelFetchTask = nil
        return models
    }

    private func fetchModelCatalog() async -> [JSONValue] {
        let process: OmpProcess
        if let existing = await modelScratchRunning() {
            process = existing
        } else {
            let created = OmpProcess(ompBin: config.ompBin, directory: config.workdir) { _ in }
            do {
                try await created.start()
            } catch {
                FileHandle.standardError.write(Data("models: scratch start failed: \(error)\n".utf8))
                failedModelsAt = Date()
                return []
            }
            process = created
            self.modelScratchProcess = created
        }
        let response = await process.request("get_available_models", timeout: 120)
        guard response.success, let list = response.data?["models"]?.arrayValue else {
            FileHandle.standardError.write(Data("models: request failed: \(response.error ?? "unknown")\n".utf8))
            failedModelsAt = Date()
            await process.stop()
            if modelScratchProcess === process { modelScratchProcess = nil }
            return []
        }
        let models = list.compactMap { entry -> JSONValue? in
            guard let id = entry["id"]?.stringValue else { return nil }
            var model: [String: JSONValue] = [
                "id": .string(id),
                "name": .string(entry["name"]?.stringValue ?? id),
                "provider": .string(
                    entry["provider"]?.stringValue
                        ?? id.split(separator: "/").first.map(String.init) ?? ""),
            ]
            let efforts = entry["thinking"]?["efforts"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !efforts.isEmpty {
                model["variants"] = .array(efforts.map { JSONValue.string($0) })
            }
            return .object(model)
        }
        failedModelsAt = nil
        cachedModels = (Date(), models)
        return models
    }
    private func modelScratchRunning() async -> OmpProcess? {
        guard let existing = modelScratchProcess, await existing.isRunning else {
            modelScratchProcess = nil
            return nil
        }
        return existing
    }

    func shutdown() async {
        await flushAll()
        for (_, session) in sessions {
            await session.shutdown()
        }
        await hub.closeAll()
    }
}
