import Foundation
import Testing

@testable import omp_bridge

/// A stand-in for `omp --mode rpc`: it announces itself, acknowledges every request and writes
/// each request line to a log, so a test can read back which prompts the engine was sent.
private struct FakeOmp {
    let root: String
    let binary: String
    let requestLog: String

    init() throws {
        root = makeTempDir("sharedqueue")
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
              printf '{"type":"response","id":"%s","command":"%s","success":true,"data":{}}\\n' "$id" "$cmd"
            done
            """
        try body.write(toFile: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary)
    }

    var config: Config {
        Config(
            port: 0, bind: "", password: "", workdir: root, ompBin: binary,
            storePath: root + "/sessions.json", stateDir: root, srcPath: nil, defaultModel: nil,
            defaultEffort: "medium", titleModel: nil, waitMax: 10800)
    }

    func prompts() -> [String] {
        let text = (try? String(contentsOfFile: requestLog, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line -> String? in
            guard line.contains("\"type\":\"prompt\"") else { return nil }
            let data = Data(line.utf8)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["message"] as? String
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
}

private func until(_ limit: Duration, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func item(_ id: String, _ text: String, kind: String? = nil) -> EnqueueRequest {
    EnqueueRequest(id: id, text: text, kind: kind, model: nil, effort: nil, attachments: nil)
}

private func accepted(_ outcome: EnqueueOutcome) -> (started: Bool, snapshot: QueueSnapshot)? {
    guard case .accepted(let started, let snapshot) = outcome else { return nil }
    return (started, snapshot)
}

private func userTexts(_ session: OmpSession) async -> [String] {
    await session.snapshotMessages().filter { $0.role == .user }.map { message in
        message.parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
    }
}

private func endTurn(_ session: OmpSession) async {
    await session.handleOmpEvent(.object(["type": .string("agent_end")]))
}

private func sessionEvents(_ hub: Hub) async -> [BridgeEvent] {
    let attachment = await hub.attach(sinceEpoch: hub.epoch, sinceSeq: 0)
    return attachment.replay.compactMap { frame in
        if case .session(_, let event) = frame.event { return event }
        return nil
    }
}

@Suite struct SharedQueueTests {
    private func makeSession(
        _ fake: FakeOmp, id: String = UUID().uuidString, hub: Hub = Hub()
    ) -> OmpSession {
        OmpSession(
            id: id, title: "Test", directory: fake.root, model: "", effort: "medium",
            config: fake.config, hub: hub, quietRegistry: QuietRegistry())
    }

    @Test func enqueueOnAnIdleSessionStartsAtOnce() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)

        let result = try #require(accepted(await session.enqueue(item("a", "hello"))))

        #expect(result.started)
        #expect(result.snapshot.queue.isEmpty)
        #expect(result.snapshot.paused == false)
        #expect(await session.isRunningValue())
        #expect(await userTexts(session) == ["hello"])
        try await until(.seconds(3)) { fake.prompts().count == 1 }
        #expect(fake.prompts() == ["hello"])
    }

    @Test func enqueueWhileRunningQueuesAndTheMessageLandsWhenItStarts() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)
        _ = await session.enqueue(item("a", "first"))

        let result = try #require(accepted(await session.enqueue(item("b", "second"))))

        #expect(result.started == false)
        #expect(result.snapshot.queue.map(\.id) == ["b"])
        #expect(await userTexts(session) == ["first"])
        #expect(fake.prompts() == ["first"])

        await endTurn(session)
        try await until(.seconds(5)) { await userTexts(session).count == 2 }
        #expect(await userTexts(session) == ["first", "second"])
        #expect(await session.queueSnapshot().queue.isEmpty)
        try await until(.seconds(5)) { fake.prompts().count == 2 }
        #expect(fake.prompts() == ["first", "second"])
    }

    @Test func enqueueingTheSameIdAgainChangesNothing() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)
        _ = await session.enqueue(item("a", "first"))
        _ = await session.enqueue(item("b", "second"))

        let again = try #require(accepted(await session.enqueue(item("b", "second"))))
        #expect(again.started == false)
        #expect(again.snapshot.queue.count == 1)

        await endTurn(session)
        try await until(.seconds(5)) { await userTexts(session).count == 2 }
        let replay = try #require(accepted(await session.enqueue(item("b", "second"))))
        #expect(replay.snapshot.queue.isEmpty)
        let startedAgain = try #require(accepted(await session.enqueue(item("a", "first"))))
        #expect(startedAgain.snapshot.queue.isEmpty)
        #expect(await userTexts(session) == ["first", "second"])
        #expect(fake.prompts().count == 2)
    }

    @Test func aQueuedItemCanBeEditedAndCancelledBeforeItStarts() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)
        _ = await session.enqueue(item("a", "first"))
        _ = await session.enqueue(item("keep", "original"))
        _ = await session.enqueue(item("drop", "never sent"))

        let edited = await session.editQueued(
            "keep", request: EditQueuedRequest(text: "edited", model: "opus", effort: "high"))
        guard case .changed(let editedSnapshot) = edited else {
            Issue.record("edit was refused: \(edited)")
            return
        }
        #expect(editedSnapshot.queue.first?.text == "edited")
        #expect(editedSnapshot.queue.first?.model == "opus")
        #expect(editedSnapshot.queue.first?.effort == "high")

        let cancelled = await session.cancelQueued("drop")
        let expected = QueueChangeOutcome.changed(
            QueueSnapshot(queue: [editedSnapshot.queue[0]], paused: false))
        #expect(cancelled == expected)
        #expect(await session.cancelQueued("drop") == expected)

        #expect(await session.cancelQueued("keep") != .alreadyStarted)
        #expect(await session.queueSnapshot().queue.isEmpty)
    }

    @Test func editingOrCancellingAnItemThatStartedIsRefused() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)
        _ = await session.enqueue(item("a", "first"))
        _ = await session.enqueue(item("b", "second"))
        await endTurn(session)
        try await until(.seconds(5)) { await userTexts(session).count == 2 }

        #expect(await session.editQueued("b", request: EditQueuedRequest(text: "late")) == .alreadyStarted)
        #expect(await session.cancelQueued("b") == .alreadyStarted)
        #expect(await session.editQueued("nobody", request: EditQueuedRequest(text: "x")) == .alreadyStarted)
    }

    @Test func stopPausesTheQueueAndKeepsItsItems() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)
        _ = await session.enqueue(item("a", "first"))
        _ = await session.enqueue(item("b", "second"))

        let result = await session.abort()

        #expect(result.stopped)
        #expect(result.paused)
        try await Task.sleep(for: .milliseconds(600))
        let snapshot = await session.queueSnapshot()
        #expect(snapshot.paused)
        #expect(snapshot.queue.map(\.id) == ["b"])
        #expect(await session.isRunningValue() == false)
        #expect(fake.prompts() == ["first"])
        #expect(await userTexts(session) == ["first"])
    }

    @Test func resumeAndEnqueueBothClearThePause() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)
        _ = await session.enqueue(item("a", "first"))
        _ = await session.enqueue(item("b", "second"))
        _ = await session.abort()

        let resumed = await session.resumeQueue()
        #expect(resumed.paused == false)
        #expect(resumed.queue.isEmpty)
        #expect(await userTexts(session).last == "second")
        await endTurn(session)

        _ = await session.enqueue(item("c", "third"))
        _ = await session.enqueue(item("d", "fourth"))
        _ = await session.abort()
        #expect(await session.queueSnapshot().paused)
        #expect(await session.queueSnapshot().queue.map(\.id) == ["d"])

        let result = try #require(accepted(await session.enqueue(item("e", "fifth"))))
        #expect(result.snapshot.paused == false)
        #expect(result.started == false)
        #expect(await userTexts(session).last == "fourth")
        #expect(result.snapshot.queue.map(\.id) == ["e"])
    }

    @Test func aLegacySendWhileATurnRunsBecomesAnItemWithoutAnEcho() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)
        _ = await session.enqueue(item("a", "first"))

        let outcome = try await session.send(text: "from an old client", model: nil, effort: nil)

        #expect(outcome.queued)
        #expect(outcome.position == 0)
        let snapshot = await session.queueSnapshot()
        #expect(snapshot.queue.map(\.text) == ["from an old client"])
        #expect(snapshot.queue.first.map { !$0.id.isEmpty } == true)
        #expect(await userTexts(session) == ["first"])

        await endTurn(session)
        try await until(.seconds(5)) { await userTexts(session).count == 2 }
        #expect(await userTexts(session) == ["first", "from an old client"])
    }

    @Test func aQueueRestoredAfterARestartComesBackPausedAndRunsNothing() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let id = UUID().uuidString
        let session = makeSession(fake, id: id)
        _ = await session.enqueue(item("a", "first"))
        let attachment = SendAttachment(
            mime: "image/png", filename: "a.png", dataBase64: Data([1, 2, 3, 4]).base64EncodedString())
        _ = await session.enqueue(
            EnqueueRequest(
                id: "b", text: "second", kind: nil, model: "opus", effort: "high",
                attachments: [attachment]))
        #expect(await session.queueSnapshot().paused == false)

        let reborn = makeSession(fake, id: id)
        let snapshot = await reborn.queueSnapshot()

        #expect(snapshot.paused)
        #expect(snapshot.queue.map(\.id) == ["b"])
        #expect(snapshot.queue.first?.model == "opus")
        #expect(
            snapshot.queue.first?.attachments
                == [QueueAttachment(mime: "image/png", filename: "a.png", size: 4)])
        #expect(await reborn.queueGreeting() == snapshot)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await reborn.isRunningValue() == false)
        #expect(fake.prompts() == ["first"])

        let resumed = await reborn.resumeQueue()
        #expect(resumed.paused == false)
        #expect(await userTexts(reborn) == ["second"])
        let files = await reborn.snapshotMessages().last?.parts.compactMap { part -> FileRef? in
            if case .file(let file) = part { return file }
            return nil
        }
        #expect(files?.count == 1)
        #expect(files?.first.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func aCompactionHoldsTheQueueBackUntilItEnds() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)
        _ = await session.enqueue(item("a", "first"))
        _ = await session.enqueue(item("b", "second"))

        await session.handleOmpEvent(.object(["type": .string("auto_compaction_start")]))
        await endTurn(session)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await session.queueSnapshot().queue.map(\.id) == ["b"])
        #expect(fake.prompts() == ["first"])

        await session.handleOmpEvent(.object(["type": .string("auto_compaction_end")]))
        try await until(.seconds(5)) { fake.prompts().count == 2 }
        #expect(fake.prompts() == ["first", "second"])
        #expect(await session.queueSnapshot().queue.isEmpty)
    }

    @Test func everyChangeReachesSubscribersAsTheFullSnapshot() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let hub = Hub()
        let session = makeSession(fake, hub: hub)
        _ = await session.enqueue(item("a", "first"))
        _ = await session.enqueue(item("b", "second"))
        _ = await session.enqueue(item("c", "third"))
        _ = await session.editQueued("c", request: EditQueuedRequest(text: "third!"))
        _ = await session.cancelQueued("b")
        _ = await session.abort()

        let snapshots = await sessionEvents(hub).compactMap { event -> QueueSnapshot? in
            if case .queue(let snapshot) = event { return snapshot }
            return nil
        }
        #expect(snapshots.map { $0.queue.map(\.id) } == [["b"], ["b", "c"], ["b", "c"], ["c"], ["c"]])
        #expect(snapshots[2].queue.last?.text == "third!")
        #expect(snapshots.map(\.paused) == [false, false, false, false, true])
        let wire = try WireCoding.encoder.encode(BridgeEvent.queue(snapshots[1]))
        let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(object["type"] as? String == "queue")
        #expect(object["paused"] as? Bool == false)
        #expect((object["queue"] as? [[String: Any]])?.count == 2)
    }

    @Test func aBadEnqueueIsRefused() async throws {
        let fake = try FakeOmp()
        defer { fake.cleanUp() }
        let session = makeSession(fake)

        guard case .invalid = await session.enqueue(item("", "x")) else {
            Issue.record("an empty id was accepted")
            return
        }
        guard case .invalid = await session.enqueue(item("a", "x", kind: "shout")) else {
            Issue.record("an unknown kind was accepted")
            return
        }
        guard case .invalid = await session.enqueue(item("a", "  ")) else {
            Issue.record("an empty item was accepted")
            return
        }
        #expect(await session.isRunningValue() == false)
    }
}
