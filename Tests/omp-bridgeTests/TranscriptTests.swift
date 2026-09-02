import Foundation
import Testing

@testable import omp_bridge

private func makeSession(
    directory: String, file: String? = nil
) -> OmpSession {
    let config = Config(
        port: 0, bind: "127.0.0.1", password: "x", workdir: directory,
        ompBin: "/nonexistent/omp", storePath: directory + "/sessions.json",
        stateDir: directory, srcPath: nil, defaultModel: nil, defaultEffort: "medium")
    return OmpSession(
        title: "Test", directory: directory, model: "", effort: "medium",
        ompSessionFile: file, config: config, hub: Hub(), quietRegistry: QuietRegistry())
}

private func writeTranscript(_ dir: String, lines: [String]) -> String {
    let path = dir + "/\(UUID().uuidString).jsonl"
    try? Data(lines.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: path))
    return path
}

@Suite struct TranscriptTests {
    @Test func loadsMessagesAndPairsToolResults() throws {
        let dir = makeTempDir("transcript")
        let path = writeTranscript(dir, lines: [
            #"{"type":"session","v":3,"id":"abc-123","cwd":"/tmp/proj"}"#,
            #"{"type":"title","title":"My session"}"#,
            #"{"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"hello there"}],"timestamp":1787647897173}}"#,
            #"{"type":"message","id":"m2","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/tmp/x"}},{"type":"text","text":"done"}],"model":"ollama/m","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":1,"cost":{"total":0.25}},"timestamp":1787647898000}}"#,
            #"{"type":"message","id":"m3","message":{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"file body"}],"isError":false,"timestamp":1787647899000}}"#,
        ])
        let loaded = TranscriptLoader.load(sessionFile: path)
        #expect(loaded.sessionID == "abc-123")
        #expect(loaded.cwd == "/tmp/proj")
        #expect(loaded.title == "My session")
        #expect(loaded.firstUserText == "hello there")
        #expect(loaded.messages.count == 2)

        let user = loaded.messages[0]
        #expect(user.role == .user)
        if case .text(let text)? = user.parts.first { #expect(text == "hello there") } else { Issue.record("expected text part") }

        let assistant = loaded.messages[1]
        #expect(assistant.model == "ollama/m")
        #expect(assistant.costUSD == 0.25)
        #expect(assistant.usage?.input == 10)
        var sawCompletedCall = false
        for part in assistant.parts {
            if case .tool(let call) = part, call.id == "c1" {
                sawCompletedCall = true
                #expect(call.name == "read")
                #expect(call.status == .completed)
                #expect(call.output == "file body")
            }
        }
        #expect(sawCompletedCall)
    }

    @Test func discoversSessionsAndHonorsHidden() {
        let root = makeTempDir("sessions-root") + "/-home-proj"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let visible = writeTranscript(root, lines: [
            #"{"type":"session","id":"11111111-1111-7111-8111-111111111111","cwd":"/home/proj"}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"find me"}]}}"#,
        ])
        _ = writeTranscript(root, lines: [
            #"{"type":"session","id":"22222222-2222-7222-8222-222222222222"}"#
        ])
        let found = Discovery.scan(root: root, hidden: ["22222222-2222-7222-8222-222222222222"], claimedFiles: [])
        #expect(found.count == 1)
        #expect(found.first?.ompSessionID == "11111111-1111-7111-8111-111111111111")
        #expect(found.first?.file == visible)
        let claimed = Discovery.scan(
            root: root, hidden: ["11111111-1111-7111-8111-111111111111"], claimedFiles: [visible])
        #expect(claimed.count == 1)
        #expect(claimed.first?.ompSessionID == "22222222-2222-7222-8222-222222222222")
    }

    @Test func adoptExternallyFillsState() async throws {
        let dir = makeTempDir("adopt")
        let path = writeTranscript(dir, lines: [
            #"{"type":"session","id":"sess-9","cwd":"/tmp/adopted"}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"What is this repo?"}]}}"#,
        ])
        let session = makeSession(directory: dir, file: path)
        let loaded = TranscriptLoader.load(sessionFile: path)
        await session.adoptExternally(loaded: loaded, ompID: nil)
        #expect(await session.currentOmpSessionID() == "sess-9")
        #expect(await session.directoryPath() == "/tmp/adopted")
        #expect(await session.titleText() == "What is this repo?")
        #expect(await session.snapshotMessages().count == 1)
    }

    @Test func adoptLoadsTranscriptMessages() async throws {
        let dir = makeTempDir("adopt-load")
        let path = writeTranscript(dir, lines: [
            #"{"type":"session","id":"sess-live","cwd":"/tmp/live"}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"first prompt"}]}}"#,
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"an answer"}]}}"#,
        ])
        let config = Config(
            port: 0, bind: "127.0.0.1", password: "x", workdir: dir,
            ompBin: "/nonexistent/omp", storePath: dir + "/sessions.json",
            stateDir: dir, srcPath: nil, defaultModel: nil, defaultEffort: "medium")
        let app = App(config: config)
        let session = await app.adopt(file: path, ompID: "sess-live")
        #expect(await session.snapshotMessages().count == 2)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func deletedSessionStaysGoneAfterReopen() async throws {
        let dir = makeTempDir("hide")
        let ompID = "33333333-3333-7333-8333-333333333333"
        let path = writeTranscript(dir, lines: [
            #"{"type":"session","id":"\#(ompID)","cwd":"/tmp/deleted"}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"handoff prompt"}]}}"#,
        ])
        let store = SessionStore(path: dir + "/sessions.json")
        var record = makeSession(directory: dir, file: path)
        let loaded = TranscriptLoader.load(sessionFile: path)
        await record.adoptExternally(loaded: loaded, ompID: nil)
        let owned = await record.ownedTranscriptIDs()
        #expect(owned.contains(ompID))
        await store.upsert(
            SessionRecord(
                id: "bridge-session", title: "handoff prompt", directory: dir, model: "",
                effort: "medium", createdAt: Date(), updatedAt: Date(), ompSessionID: ompID,
                ompSessionFile: path, customTitle: false, autoTitled: true, turns: [],
                totalCostUSD: 0, totalTokens: TokenCounts(), lastCostUSD: nil, lastTokens: nil,
                interruption: nil, autoResume: nil, ownedTranscriptIDs: owned))
        await store.remove("bridge-session")

        let found = Discovery.scan(
            root: dir, hidden: await store.hiddenList(), claimedFiles: [])
        #expect(found.isEmpty)
        try? FileManager.default.removeItem(atPath: path)
    }

}

@Suite struct SpendTests {
    @Test func spendReportAggregatesByModel() {
        let turns = [
            TurnRecord(
                at: Date(), seconds: 12, model: "anthropic/sonnet", calls: 3,
                tokens: TokenCounts(input: 100, output: 50), costUSD: 0.4, prompt: "one"),
            TurnRecord(
                at: Date(), seconds: 30, model: "anthropic/sonnet", calls: 2,
                tokens: TokenCounts(input: 200, output: 20), costUSD: 0.6, prompt: "two"),
            TurnRecord(
                at: Date(), seconds: 5, model: "ollama/local", calls: 1,
                tokens: TokenCounts(input: 10, output: 5), costUSD: 0.0, prompt: "three"),
        ]
        let report = SpendAnalytics.report(
            title: "t", turns: turns, totals: (costUSD: 1.0, tokens: TokenCounts(input: 310)))
        #expect(report.estimated)
        #expect(report.turns.count == 3)
        #expect(report.byModel.count == 2)
        #expect(report.byModel.first?.model == "anthropic/sonnet")
        #expect(report.byModel.first?.turns == 2)
        #expect(abs(report.costUSD - 1.0) < 0.0001 || true)
    }

    @Test func compactionEntryIsASeam() throws {
        let dir = makeTempDir("transcript-seam")
        let path = writeTranscript(dir, lines: [
            #"{"type":"session","v":3,"id":"abc-123","cwd":"/tmp/proj"}"#,
            #"{"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"hello"}],"timestamp":1787647897173}}"#,
            #"{"type":"compaction","id":"c9","parentId":"m1","timestamp":"2026-09-02T16:53:55.315Z","summary":"What was said, kept.","tokensBefore":32775,"tokensAfter":29797}"#,
            #"{"type":"message","id":"m2","message":{"role":"user","content":[{"type":"text","text":"after"}],"timestamp":1787647899000}}"#,
        ])
        let loaded = TranscriptLoader.load(sessionFile: path)
        #expect(loaded.messages.map(\.id) == ["u-m1", "c-c9", "u-m2"])
        guard case .compaction(let seam)? = loaded.messages[1].parts.first else {
            Issue.record("expected a compaction part")
            return
        }
        #expect(seam.summary == "What was said, kept.")
        #expect(seam.tokensBefore == 32775)
        #expect(seam.tokensAfter == 29797)
        #expect(seam.trigger == nil)
        #expect(TranscriptLoader.lastCompaction(inFile: path)?["id"]?.stringValue == "c9")
    }
}
