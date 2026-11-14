import Foundation
import Testing

@testable import omp_bridge

/// A stand-in for `omp --mode rpc` that acknowledges every request, logs each one, and answers
/// `get_state` with whatever state the test gives it.
private struct Engine {
    let root: String
    let binary: String
    let requestLog: String

    init(state: String = "{}") throws {
        root = makeTempDir("engine-keep")
        requestLog = root + "/requests.log"
        binary = root + "/fake-omp"
        FileManager.default.createFile(atPath: requestLog, contents: Data())
        let body = """
            #!/bin/sh
            echo '{"type":"ready","supportedProtocolVersions":[1]}'
            while IFS= read -r line; do
              echo "$line" >> "\(requestLog)"
              id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
              cmd=$(printf '%s' "$line" | sed -n 's/.*"type":"\\([^"]*\\)".*/\\1/p')
              data='{}'
              if [ "$cmd" = "get_state" ]; then data='\(state)'; fi
              printf '{"type":"response","id":"%s","command":"%s","success":true,"data":%s}\\n' "$id" "$cmd" "$data"
            done
            """
        try writeExecutable(body, to: binary)
    }

    var config: Config {
        Config(
            port: 0, bind: "", password: "", workdir: root, ompBin: binary,
            storePath: root + "/sessions.json", stateDir: root, srcPath: nil, defaultModel: nil,
            defaultEffort: "medium", titleModel: nil, waitMax: 10800)
    }

    func session(
        transcript: String? = nil, registry: QuietRegistry = QuietRegistry()
    ) -> OmpSession {
        OmpSession(
            title: "Test", directory: root, model: "", effort: "medium", ompSessionFile: transcript,
            config: config, hub: Hub(), quietRegistry: registry)
    }

    func requests() -> [String] {
        let text = (try? String(contentsOfFile: requestLog, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["type"] as? String
        }
    }
}

private func gone(_ pid: Int) async -> Bool {
    for _ in 0..<250 {
        if kill(pid_t(pid), 0) != 0 { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@Suite struct EngineKeepTests {
    @Test func anIdleEngineIsLetGo() async throws {
        let engine = try Engine()
        let session = engine.session()
        let pid = try #require(await session.ensureProcess().processID)
        let since = try #require(await session.idleEngineSince())
        #expect(await session.releaseIdleEngine(quietSince: since))
        #expect(await gone(pid))
        #expect(await session.idleEngineSince() == nil)
    }

    @Test func anEngineWithBackgroundWorkIsKept() async throws {
        let engine = try Engine(state: #"{"hasPendingAsyncWork":true}"#)
        let session = engine.session()
        let pid = try #require(await session.ensureProcess().processID)
        let since = try #require(await session.idleEngineSince())
        #expect(await !session.releaseIdleEngine(quietSince: since))
        #expect(kill(pid_t(pid), 0) == 0)
        await session.shutdown()
        #expect(await gone(pid))
    }

    @Test func anEngineThatMovedAfterItWasReadIsKept() async throws {
        let engine = try Engine()
        let session = engine.session()
        let pid = try #require(await session.ensureProcess().processID)
        let since = try #require(await session.idleEngineSince())
        try await Task.sleep(for: .milliseconds(20))
        await session.handleOmpEvent(.object(["type": .string("queue_update")]))
        #expect(await !session.releaseIdleEngine(quietSince: since))
        await session.shutdown()
        #expect(await gone(pid))
    }

    @Test func clearingPutsTheEngineOnAFreshTranscript() async throws {
        let engine = try Engine()
        let session = engine.session()
        let pid = try #require(await session.ensureProcess().processID)
        try await session.clear()
        #expect(engine.requests().contains("new_session"))
        #expect(await session.snapshotMessages().isEmpty)
        await session.shutdown()
        #expect(await gone(pid))
    }

    @Test func clearingWithoutAnEngineLeavesTheOldTranscriptBehind() async throws {
        let engine = try Engine()
        let session = engine.session(transcript: engine.root + "/old.jsonl")
        try await session.clear()
        #expect(await session.sessionFile() == nil)
        #expect(!engine.requests().contains("new_session"))
    }

    @Test func aTurnClearsOnlyItsOwnJournalEntry() async throws {
        let root = makeTempDir("journal")
        let journal = TurnJournal(path: root + "/turns.json")
        await journal.write(
            JournalEntry(
                turnID: "t-new", sessionID: "s", ompSessionFile: nil, prompt: "p", startedAt: Date(),
                pid: nil))
        await journal.clear("s", turnID: "t-old")
        #expect(await journal.interruptedEntries().map(\.turnID) == ["t-new"])
        await journal.clear("s", turnID: "t-new")
        #expect(await journal.interruptedEntries().isEmpty)
    }

}
