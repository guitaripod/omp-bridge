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
            config: config, hub: hub, quietRegistry: quietRegistry)
        sessions[session.id] = session
        return session
    }

    func liveSession(id: String) -> OmpSession? { sessions[id] }

    func liveSessionIDs() -> [String] { Array(sessions.keys) }

    func knowsSession(id: String) -> Bool { sessions[id] != nil }

    func adoptDiscovered(id wanted: String) async -> OmpSession? {
        if let live = sessions[wanted] { return live }
        let claimedFiles = await claimedFiles()
        let found = Discovery.scan(
            root: config.ompSessionsRoot, hidden: [], claimedFiles: claimedFiles)
        guard let match = found.first(where: { $0.ompSessionID == wanted }) else { return nil }
        return await adopt(file: match.file, ompID: match.ompSessionID)
    }

    func adopt(file: String, ompID: String?) async -> OmpSession {
        let loaded = TranscriptLoader.load(sessionFile: file)
        let session = OmpSession(
            title: loaded.title ?? OmpSession.derivedTitle(from: loaded.firstUserText ?? "Session"),
            directory: loaded.cwd ?? config.workdir,
            model: config.defaultModel ?? "",
            effort: config.defaultEffort,
            ompSessionFile: file, config: config, hub: hub, quietRegistry: quietRegistry)
        await session.adoptExternally(loaded: loaded, ompID: ompID)
        sessions[session.id] = session
        return session
    }

    func deleteSession(id: String) async {
        if let session = sessions.removeValue(forKey: id) {
            await session.shutdown()
            await store.remove(id)
        } else {
            _ = await store.remove(id)
        }
        lastSummaries.removeValue(forKey: id)
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
            config: config, hub: hub, quietRegistry: quietRegistry)
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
            root: config.ompSessionsRoot, hidden: hidden, claimedFiles: claimedFiles)
        for item in discovered {
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
            await store.upsert(await record(for: session))
        }
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
            autoResume: nil)
    }

    func flushAll() async {
        for (_, session) in sessions {
            await store.upsert(await record(for: session))
        }
        await store.flush()
    }

    // MARK: interruptions

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

    func shutdown() async {
        await flushAll()
        for (_, session) in sessions {
            await session.shutdown()
        }
        await hub.closeAll()
    }
}
