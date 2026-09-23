import Foundation
import Testing

@testable import omp_bridge

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func wholeMillis(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
}

private enum Row {
    static func header(_ at: Date, id: String = "sess-clock") -> String {
        #"{"type":"session","version":3,"id":"\#(id)","cwd":"/home/clock","timestamp":"\#(iso(at))"}"#
    }

    static func prompt(_ at: Date, _ text: String = "what changed") -> String {
        #"{"type":"message","id":"u\#(Int(at.timeIntervalSince1970 * 1000))","timestamp":"\#(iso(at))","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}],"timestamp":\#(Int(at.timeIntervalSince1970 * 1000))}}"#
    }

    static func answer(_ at: Date, stop: String, call: String? = nil) -> String {
        let content =
            call.map { #"[{"type":"toolCall","id":"\#($0)","name":"read","arguments":{"path":"/x"}}]"# }
            ?? #"[{"type":"text","text":"an answer"}]"#
        return #"{"type":"message","id":"a\#(Int(at.timeIntervalSince1970 * 1000))","timestamp":"\#(iso(at))","message":{"role":"assistant","content":\#(content),"stopReason":"\#(stop)","timestamp":\#(Int(at.timeIntervalSince1970 * 1000))}}"#
    }

    static func result(_ at: Date, call: String, body: String = "file body") -> String {
        #"{"type":"message","id":"r\#(Int(at.timeIntervalSince1970 * 1000))","timestamp":"\#(iso(at))","message":{"role":"toolResult","toolCallId":"\#(call)","content":[{"type":"text","text":"\#(body)"}],"isError":false,"timestamp":\#(Int(at.timeIntervalSince1970 * 1000))}}"#
    }

    static func toolStart(_ at: Date) -> String {
        #"{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"c9","toolName":"bash"},"timestamp":"\#(iso(at))"}"#
    }

    static func notice(_ at: Date, kind: String) -> String {
        #"{"type":"custom_message","customType":"\#(kind)","content":"<system-notice>done</system-notice>","display":true,"timestamp":"\#(iso(at))"}"#
    }

    static func compaction(_ at: Date) -> String {
        #"{"type":"compaction","timestamp":"\#(iso(at))","summary":"Earlier turns","tokensBefore":1000,"tokensAfter":100}"#
    }

    static func branch(_ at: Date) -> String {
        #"{"type":"branch_summary","timestamp":"\#(iso(at))","fromId":"f1","summary":""}"#
    }

    static func exit(_ at: Date) -> String {
        #"{"type":"custom","customType":"session_exit","data":{"reason":"sigterm","kind":"signal"},"timestamp":"\#(iso(at))"}"#
    }

    static func bookkeeping(_ at: Date) -> [String] {
        [
            #"{"type":"model_change","timestamp":"\#(iso(at))","model":"ollama-cloud/glm-5.3-flash"}"#,
            #"{"type":"thinking_level_change","timestamp":"\#(iso(at))","thinkingLevel":"low"}"#,
            #"{"type":"service_tier_change","timestamp":"\#(iso(at))","serviceTier":null}"#,
            #"{"type":"credential_pin","timestamp":"\#(iso(at))","provider":"anthropic","hash":"00"}"#,
            #"{"type":"title_change","timestamp":"\#(iso(at))","title":"Renamed","source":"auto"}"#,
            #"{"type":"a_row_from_a_newer_engine","timestamp":"\#(iso(at))"}"#,
        ]
    }
}

private func transcript(_ lines: [String], in dir: String? = nil, modified: Date? = nil) -> String {
    let folder = dir ?? makeTempDir("clock")
    let path = folder + "/\(UUID().uuidString).jsonl"
    try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
    if let modified {
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }
    return path
}

private func append(_ lines: [String], to path: String, modified: Date) throws {
    let handle = try #require(FileHandle(forWritingAtPath: path))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
}

private func config(in dir: String) -> Config {
    Config(
        port: 0, bind: "127.0.0.1", password: "x", workdir: dir,
        ompBin: "/nonexistent/omp", storePath: dir + "/sessions.json",
        stateDir: dir, srcPath: nil, defaultModel: nil, defaultEffort: "medium", titleModel: nil)
}

private func session(for path: String, restored: (Date, Date)? = nil, forkedAt: Date? = nil) -> OmpSession {
    let dir = (path as NSString).deletingLastPathComponent
    return OmpSession(
        id: UUID().uuidString, title: "Clock", directory: dir, model: "", effort: "medium",
        ompSessionFile: path, config: config(in: dir), hub: Hub(), quietRegistry: QuietRegistry(),
        journal: nil, restoredDates: restored.map { (createdAt: $0.0, updatedAt: $0.1) },
        forkedAt: forkedAt)
}

private func same(_ lhs: Date?, _ rhs: Date) -> Bool {
    guard let lhs else { return false }
    return abs(lhs.timeIntervalSince(rhs)) < 0.001
}

@Suite struct TranscriptClockTests {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// The row an engine files on its way out is the one that put every chat a restart closed
    /// at the top of the list: it is the newest thing in the file, and it is not the conversation.
    @Test func anEngineSigningOffDoesNotMoveTheClock() {
        let said = base.addingTimeInterval(20)
        let path = transcript([
            Row.header(base), Row.prompt(base.addingTimeInterval(10)),
            Row.answer(said, stop: "stop"), Row.exit(base.addingTimeInterval(86_400)),
        ], modified: base.addingTimeInterval(86_400))
        let loaded = TranscriptLoader.load(sessionFile: path)
        #expect(same(loaded.updatedAt, said))
        #expect(loaded.activity == TranscriptActivity(lastSaid: said, turnOpen: false, engineExited: true))
        #expect(TranscriptClock.read(atPath: path) == loaded.activity)
    }

    @Test func theEnginesBookkeepingIsNotSpeech() {
        let said = base.addingTimeInterval(20)
        let later = base.addingTimeInterval(600)
        let path = transcript(
            [Row.header(base), Row.prompt(base.addingTimeInterval(10)), Row.answer(said, stop: "stop")]
                + Row.bookkeeping(later) + [Row.exit(later)], modified: later)
        #expect(same(TranscriptLoader.load(sessionFile: path).updatedAt, said))
        #expect(same(TranscriptClock.read(atPath: path).lastSaid, said))
    }

    @Test func aChatNobodySpokeInIsDatedFromItsStart() {
        let path = transcript(
            [Row.header(base)] + Row.bookkeeping(base.addingTimeInterval(60))
                + [Row.exit(base.addingTimeInterval(120))],
            modified: base.addingTimeInterval(120))
        let loaded = TranscriptLoader.load(sessionFile: path)
        #expect(loaded.activity.lastSaid == nil)
        #expect(same(loaded.updatedAt, base))
    }

    @Test func aTurnIsOpenUntilItsAnswerEnds() {
        let at = base.addingTimeInterval(30)
        let cases: [(String, [String], Bool)] = [
            ("a prompt waiting", [Row.prompt(at)], true),
            ("an answer that called a tool", [Row.answer(at, stop: "toolUse", call: "c1")], true),
            ("a tool's result", [Row.answer(base, stop: "toolUse", call: "c1"), Row.result(at, call: "c1")], true),
            ("a tool starting", [Row.toolStart(at)], true),
            ("a background job reporting", [Row.notice(at, kind: "async-result")], true),
            ("an answer that stopped", [Row.answer(at, stop: "stop")], false),
            ("an answer that failed", [Row.answer(at, stop: "error")], false),
            ("an answer cut off", [Row.answer(at, stop: "length")], false),
            ("an aborted answer", [Row.answer(base, stop: "aborted"), Row.notice(at, kind: "interrupted-thinking")], false),
            ("a move along the tree", [Row.answer(base, stop: "stop"), Row.branch(at)], false),
        ]
        for (name, rows, open) in cases {
            let path = transcript([Row.header(base)] + rows + [Row.exit(base.addingTimeInterval(90))])
            let activity = TranscriptClock.read(atPath: path)
            #expect(activity.turnOpen == open, "\(name)")
            #expect(same(activity.lastSaid, at), "\(name)")
            #expect(activity.engineExited, "\(name)")
            #expect(TranscriptLoader.load(sessionFile: path).activity == activity, "\(name)")
        }
    }

    /// oh-my-pi compacts between turns and in the middle of one alike, so the seam dates the
    /// conversation and the row before it says whether a turn is still running.
    @Test func aCompactionLeavesTheTurnAsItFoundIt() {
        let seam = base.addingTimeInterval(40)
        let midTurn = transcript([
            Row.header(base), Row.answer(base.addingTimeInterval(10), stop: "toolUse", call: "c1"),
            Row.result(base.addingTimeInterval(20), call: "c1"), Row.compaction(seam),
        ])
        let betweenTurns = transcript([
            Row.header(base), Row.answer(base.addingTimeInterval(10), stop: "stop"), Row.compaction(seam),
        ])
        #expect(TranscriptClock.read(atPath: midTurn) == TranscriptActivity(lastSaid: seam, turnOpen: true))
        #expect(TranscriptClock.read(atPath: betweenTurns) == TranscriptActivity(lastSaid: seam, turnOpen: false))
    }

    @Test func aTailOfOneEnormousResultIsReadThroughAWiderWindow() {
        let said = base.addingTimeInterval(20)
        let huge = String(repeating: "x", count: 300 * 1024)
        let path = transcript([
            Row.header(base), Row.answer(base.addingTimeInterval(10), stop: "toolUse", call: "c1"),
            Row.result(said, call: "c1", body: huge), Row.exit(base.addingTimeInterval(500)),
        ])
        #expect(
            TranscriptClock.read(atPath: path)
                == TranscriptActivity(lastSaid: said, turnOpen: true, engineExited: true))
    }

    @Test func liveMeansOpenRecentAndStillRunning() {
        let said = base.addingTimeInterval(100)
        let horizon = base
        #expect(TranscriptActivity(lastSaid: said, turnOpen: true).isLive(after: horizon))
        #expect(!TranscriptActivity(lastSaid: said, turnOpen: false).isLive(after: horizon))
        #expect(!TranscriptActivity(lastSaid: said, turnOpen: true, engineExited: true).isLive(after: horizon))
        #expect(!TranscriptActivity(lastSaid: said, turnOpen: true).isLive(after: said))
        #expect(!TranscriptActivity(lastSaid: nil, turnOpen: true).isLive(after: horizon))
    }

    /// The store can only remember what the last process believed, and every process before this
    /// one believed the file's date — so a restored chat is dated by its own transcript, which
    /// also puts right every chat an earlier restart stamped.
    @Test func aRestoredChatIsDatedByItsTranscript() async {
        let said = base.addingTimeInterval(20)
        let stampedByARestart = base.addingTimeInterval(86_400)
        let path = transcript([
            Row.header(base), Row.prompt(base.addingTimeInterval(10)), Row.answer(said, stop: "stop"),
            Row.exit(stampedByARestart),
        ], modified: stampedByARestart)
        let restored = session(for: path, restored: (base, stampedByARestart))
        await restored.adoptExternally(loaded: TranscriptLoader.load(sessionFile: path), ompID: nil)
        #expect(same(await restored.updatedDate(), said))
        await restored.refreshFromTranscriptIfIdle()
        #expect(same(await restored.updatedDate(), said))
    }

    @Test func aChatARestartClosedIsNotWornAsLive() async {
        let now = wholeMillis(Date())
        let path = transcript([
            Row.header(now.addingTimeInterval(-60)), Row.prompt(now.addingTimeInterval(-30)),
            Row.answer(now.addingTimeInterval(-25), stop: "toolUse", call: "c1"), Row.exit(now),
        ], modified: now)
        let restored = session(for: path)
        await restored.adoptExternally(loaded: TranscriptLoader.load(sessionFile: path), ompID: nil)
        await restored.refreshFromTranscriptIfIdle()
        #expect(await restored.externallyLiveValue() == false)
        #expect(await restored.summarySnapshot().active == nil)
    }

    @Test func aFinishedAnswerIsNotWornAsLive() async {
        let now = wholeMillis(Date())
        let path = transcript([
            Row.header(now.addingTimeInterval(-60)), Row.prompt(now.addingTimeInterval(-3)),
            Row.answer(now.addingTimeInterval(-1), stop: "stop"),
        ], modified: now)
        let chat = session(for: path)
        await chat.adoptExternally(loaded: TranscriptLoader.load(sessionFile: path), ompID: nil)
        await chat.refreshFromTranscriptIfIdle()
        #expect(await chat.externallyLiveValue() == false)
    }

    /// A turn somebody runs from a terminal is live while it is open and settles the moment its
    /// answer ends, and the chat's clock follows what is said in it even when a row adds no
    /// message of its own.
    @Test func aTurnRunFromATerminalIsFollowed() async throws {
        let now = wholeMillis(Date())
        let path = transcript([
            Row.header(now.addingTimeInterval(-60)), Row.prompt(now.addingTimeInterval(-6)),
            Row.answer(now.addingTimeInterval(-5), stop: "toolUse", call: "c1"),
        ], modified: now.addingTimeInterval(-5))
        let chat = session(for: path)
        await chat.adoptExternally(loaded: TranscriptLoader.load(sessionFile: path), ompID: nil)
        await chat.refreshFromTranscriptIfIdle()
        #expect(await chat.externallyLiveValue())
        let messages = await chat.snapshotMessages().count

        try append([Row.result(now.addingTimeInterval(-4), call: "c1")], to: path, modified: now.addingTimeInterval(-4))
        await chat.refreshFromTranscriptIfIdle()
        #expect(await chat.snapshotMessages().count == messages)
        #expect(same(await chat.updatedDate(), now.addingTimeInterval(-4)))
        #expect(await chat.externallyLiveValue())

        try append([Row.answer(now.addingTimeInterval(-2), stop: "stop")], to: path, modified: now.addingTimeInterval(-2))
        await chat.refreshFromTranscriptIfIdle()
        #expect(same(await chat.updatedDate(), now.addingTimeInterval(-2)))
        #expect(await chat.externallyLiveValue() == false)
    }

    /// What this bridge's own turn left behind is never somebody else's live turn, even when the
    /// engine died with a tool call open.
    @Test func theBridgesOwnTailIsNotSomebodyElsesTurn() async {
        let now = wholeMillis(Date())
        let path = transcript([
            Row.header(now.addingTimeInterval(-60)), Row.prompt(now.addingTimeInterval(-20)),
            Row.answer(now.addingTimeInterval(-10), stop: "toolUse", call: "c1"),
        ], modified: now.addingTimeInterval(-10))
        let chat = session(for: path)
        await chat.adoptExternally(loaded: TranscriptLoader.load(sessionFile: path), ompID: nil)
        await chat.settleOwnTurn()
        await chat.refreshFromTranscriptIfIdle()
        #expect(await chat.externallyLiveValue() == false)
    }

    @Test func aNameIsNotSomethingSaid() async {
        let said = base.addingTimeInterval(20)
        let path = transcript([Row.header(base), Row.prompt(base.addingTimeInterval(10)), Row.answer(said, stop: "stop")])
        let chat = session(for: path)
        await chat.adoptExternally(loaded: TranscriptLoader.load(sessionFile: path), ompID: nil)
        await chat.rename("A better name")
        #expect(same(await chat.updatedDate(), said))
        #expect(await chat.titleText() == "A better name")
    }

    /// A fork is a new chat whose history happens to be old: it is dated from the moment it was
    /// made until somebody speaks in it, and a restart keeps it there.
    @Test func aForkIsDatedFromWhenItWasMade() async throws {
        let said = base.addingTimeInterval(20)
        let forked = base.addingTimeInterval(3600)
        let path = transcript(
            [Row.header(base), Row.prompt(base.addingTimeInterval(10)), Row.answer(said, stop: "stop")],
            modified: base.addingTimeInterval(20))
        let fork = session(for: path, forkedAt: forked)
        await fork.adoptExternally(loaded: TranscriptLoader.load(sessionFile: path), ompID: nil)
        #expect(same(await fork.updatedDate(), forked))
        #expect(same(await fork.createdDate(), forked))

        let restored = session(for: path, restored: (forked, forked), forkedAt: forked)
        await restored.adoptExternally(loaded: TranscriptLoader.load(sessionFile: path), ompID: nil)
        #expect(same(await restored.updatedDate(), forked))

        let spoken = forked.addingTimeInterval(60)
        try append([Row.prompt(spoken, "carry on from here")], to: path, modified: spoken)
        await restored.refreshFromTranscriptIfIdle()
        #expect(same(await restored.updatedDate(), spoken))
    }

    @Test func forkingStampsTheForkAndTheStoreKeepsIt() async throws {
        let dir = makeTempDir("clock-fork")
        let path = transcript(
            [Row.header(base), Row.prompt(base.addingTimeInterval(10)), Row.answer(base.addingTimeInterval(20), stop: "stop")],
            in: dir)
        let app = App(config: config(in: dir))
        let source = await app.adopt(file: path, ompID: "sess-clock")
        let before = Date()
        let fork = try await app.forkSession(id: source.id)
        let forkID = await fork.id
        let forkedAt = try #require(await fork.forkedAt)
        #expect(forkedAt >= before)
        #expect(same(await fork.updatedDate(), forkedAt))
        await app.flushAll()
        let stored = await SessionStore(path: dir + "/sessions.json").allRecords()
        let kept = try #require(stored.first(where: { $0.id == forkID })?.forkedAt)
        #expect(abs(kept.timeIntervalSince(forkedAt)) < 1)
    }

    @Test func aDiscoveredChatIsDatedByWhatWasSaid() {
        let root = makeTempDir("clock-discovery") + "/-home-clock"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let said = base.addingTimeInterval(20)
        _ = transcript([
            Row.header(base), Row.prompt(base.addingTimeInterval(10)), Row.answer(said, stop: "stop"),
            Row.exit(base.addingTimeInterval(86_400)),
        ], in: root, modified: base.addingTimeInterval(86_400))
        let found = Discovery.scan(root: root, hidden: [], claimedFiles: [], cache: DiscoveryCache())
        #expect(found.count == 1)
        #expect(same(found.first?.updatedAt, said))
        #expect(same(found.first?.createdAt, base))
    }

    @Test func aSearchHitIsDatedByWhatWasSaid() async {
        let root = makeTempDir("clock-search")
        try? FileManager.default.createDirectory(atPath: root + "/-home-clock", withIntermediateDirectories: true)
        let said = base.addingTimeInterval(20)
        _ = transcript([
            Row.header(base), Row.prompt(base.addingTimeInterval(10), "find the flamingo"),
            Row.answer(said, stop: "stop"), Row.exit(base.addingTimeInterval(86_400)),
        ], in: root + "/-home-clock", modified: base.addingTimeInterval(86_400))
        let response = await TranscriptSearch.search(root: root, query: "flamingo", limit: 5)
        #expect(response.hits.count == 1)
        #expect(same(response.hits.first?.updatedAt, said))
    }
}
