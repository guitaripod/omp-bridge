import Foundation
import Testing

@testable import omp_bridge

private func prompt(_ id: String, _ text: String, at seconds: TimeInterval) -> Message {
    Message(
        id: id, role: .user, parts: [.text(text)], createdAt: Date(timeIntervalSince1970: seconds),
        seconds: nil, model: nil, usage: nil, costUSD: nil)
}

private func answer(_ id: String, _ text: String, at seconds: TimeInterval) -> Message {
    Message(
        id: id, role: .assistant, parts: [.text(text)], createdAt: Date(timeIntervalSince1970: seconds),
        seconds: nil, model: nil, usage: nil, costUSD: nil)
}

private func conversation(_ count: Int) -> [Message] {
    (1...count).flatMap { turn in
        [
            prompt("u-\(turn)", "message \(turn)", at: TimeInterval(turn * 100)),
            answer("a-\(turn)", "answer \(turn)", at: TimeInterval(turn * 100 + 10)),
        ]
    }
}

/// A stand-in for `omp -p` that prints `reply` whatever it is asked.
private func fakeOmp(in dir: String, reply: String) throws -> String {
    let path = dir + "/omp"
    let script = "#!/bin/sh\ncat <<'REPLY'\n\(reply)\nREPLY\n"
    try writeExecutable(script, to: path)
    return path
}

private func config(_ dir: String, omp: String) -> Config {
    Config(
        port: 0, bind: "127.0.0.1", password: "x", workdir: dir, ompBin: omp,
        storePath: dir + "/sessions.json", stateDir: dir, srcPath: nil, defaultModel: nil,
        defaultEffort: "medium", titleModel: nil, waitMax: 10800)
}

private func transcript(_ dir: String, prompts: Int) throws -> String {
    var lines = [#"{"type":"session","v":3,"id":"s-chapters","cwd":"/tmp/proj"}"#]
    for turn in 1...prompts {
        let at = 1_794_295_600_000 + turn * 60_000
        lines.append(
            #"{"type":"message","id":"m\#(turn)","message":{"role":"user","content":[{"type":"text","text":"step \#(turn)"}],"timestamp":\#(at)}}"#)
        lines.append(
            #"{"type":"message","id":"r\#(turn)","message":{"role":"assistant","content":[{"type":"text","text":"did \#(turn)"}],"timestamp":\#(at + 5000)}}"#)
    }
    let path = dir + "/\(UUID().uuidString).jsonl"
    try Data(lines.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: path))
    return path
}

private func settle(_ session: OmpSession, past revision: Int) async -> Bool {
    for _ in 0..<100 {
        if (await session.chapterRecord().revision ?? 0) > revision { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

@Suite struct ChapterVerdictTests {
    @Test func readsTheThreeShapes() {
        #expect(Titler.verdict(from: "KEEP", current: "Fix login", count: 3) == .kept)
        #expect(
            Titler.verdict(from: "RENAME: Fix OAuth login", current: "Fix login", count: 3)
                == .renamed("Fix OAuth login"))
        #expect(
            Titler.verdict(from: "MOVED 2: Ship the release", current: "Fix login", count: 3)
                == .moved(title: "Ship the release", start: 2))
    }

    @Test func aLocalEngineThatThinksFirstIsReadPastItsThinking() {
        let raw = "<think>Maybe KEEP? No, RENAME: wrong. The topic moved at 3.</think>\n**MOVED 3: Speed up the build**"
        #expect(Titler.verdict(from: raw, current: "Fix login", count: 4) == .moved(title: "Speed up the build", start: 3))
        let unopened = "the person asked about KEEP earlier\n</think>\nKEEP"
        #expect(Titler.verdict(from: unopened, current: "Fix login", count: 4) == .kept)
    }

    @Test func aMoveOutsideTheMessagesShownStartsAtTheNewest() {
        #expect(
            Titler.verdict(from: "MOVED 9: Ship it", current: "Fix login", count: 3)
                == .moved(title: "Ship it", start: 3))
    }

    @Test func restatingTheTitleIsAKeepAndNoAnswerIsAFailure() {
        #expect(Titler.verdict(from: "RENAME: fix login", current: "Fix login", count: 2) == .kept)
        #expect(Titler.verdict(from: "MOVED 1: Fix Login", current: "Fix login", count: 2) == .kept)
        #expect(Titler.verdict(from: "", current: "Fix login", count: 2) == .failed)
        #expect(Titler.verdict(from: "Sure: here you go", current: "Fix login", count: 2) == .failed)
        #expect(Titler.verdict(from: "Tune the cache", current: "Fix login", count: 2) == .renamed("Tune the cache"))
    }

    @Test func aSplitReadsItsLinesInOrderAndLeavesTheOpenChapterUnsummed() throws {
        let raw = """
            <think>let me split</think>
            Here are the chapters:
            2 | Bridge setup | Set up the bridge config.
            5 | Test fixes | Fixed the flaky tests.
            3 | Out of order | Ignored.
            7 | Release | Shipping it now.
            """
        let segments = try #require(Titler.segments(from: raw, count: 9))
        #expect(segments.map(\.start) == [1, 5, 7])
        #expect(segments.map(\.title) == ["Bridge setup", "Test fixes", "Release"])
        #expect(segments[0].gist == "Set up the bridge config.")
        #expect(segments[2].gist == nil)
        #expect(Titler.segments(from: "no chapters here", count: 9) == nil)
    }

    @Test func aSplitAtNearlyEveryMessageOrNumberedByChapterIsNoAnswer() {
        let everyOne = (1...12).map { "\($0) | Step \($0) | Did step \($0)." }.joined(separator: "\n")
        #expect(Titler.segments(from: everyOne, count: 12) == nil)
        let numbered = "1 | One | Did one.\n2 | Two | Did two.\n3 | Three |"
        #expect(Titler.segments(from: numbered, count: 30) == nil)
        let three = "1 | One | Did one.\n5 | Two | Did two.\n9 | Three |"
        #expect(Titler.segments(from: three, count: 12)?.count == 3)
        #expect(Titler.mostChapters(among: 6) == 2)
        #expect(Titler.mostChapters(among: 150) == 12)
    }

    @Test func aSplitFinerThanTheCapFoldsItsShortestChaptersIntoTheOnesBefore() throws {
        let starts = [1, 3, 5, 10, 14, 15, 17, 20, 23, 25, 27, 30, 32]
        let raw = starts.enumerated().map { "\($1) | Part \($0 + 1) | Did part \($0 + 1)." }
            .joined(separator: "\n")
        let segments = try #require(Titler.segments(from: raw, count: 33))
        #expect(segments.count == 11)
        #expect(segments.map(\.start) == [1, 5, 10, 15, 17, 20, 23, 25, 27, 30, 32])
        #expect(segments[1].title == "Part 3" && segments[1].gist == "Did part 3.")
        #expect(segments.last?.gist == nil)
    }

    @Test func aGistIsTheLastLineWithoutQuotes() {
        #expect(Titler.gistLine(from: "<think>hmm</think>\n\"Moved the login to OAuth.\"") == "Moved the login to OAuth.")
        #expect(Titler.gistLine(from: "  ") == nil)
    }
}

@Suite struct ChapterBookTests {
    @Test func theFirstMessageOpensChapterOneAndALaterOneOnlyRenamesIt() {
        var chapters: [Chapter] = []
        let one = [prompt("u-1", "hi", at: 100)]
        #expect(ChapterBook.recorded(&chapters, messages: one, title: "Hi", priorTitle: "New chat", namer: .prompt))
        #expect(chapters.count == 1)
        #expect(chapters[0].turn == 1 && chapters[0].namedBy == .prompt)
        let two = one + [prompt("u-2", "more", at: 200)]
        #expect(!ChapterBook.recorded(&chapters, messages: two, title: "Hi", priorTitle: "Hi", namer: .prompt))
        #expect(ChapterBook.recorded(&chapters, messages: two, title: "More", priorTitle: "Hi", namer: .prompt))
        #expect(chapters.count == 1 && chapters[0].title == "More")
    }

    @Test func aMoveOpensAChapterAndHandsBackTheOneItClosed() {
        let messages = conversation(6)
        var chapters: [Chapter] = []
        let closed = ChapterBook.opened(
            &chapters, messages: messages, title: "Release", atTurn: 4, priorTitle: "Setup")
        #expect(closed == 0)
        #expect(chapters.map(\.title) == ["Setup", "Release"])
        #expect(chapters[0].namedBy == .kept)
        #expect(chapters[1].turn == 4 && chapters[1].messageID == "u-4")
        let input = ChapterBook.gistInput(chapters, messages: messages, closed: 0)
        #expect(input?.prompts == ["message 1", "message 2", "message 3"])
        #expect(input?.answer == "answer 3")
    }

    @Test func aMoveAtOrBeforeTheCurrentStartGoesToTheNextMessageOrNowhere() {
        let messages = conversation(6)
        var chapters: [Chapter] = []
        _ = ChapterBook.opened(&chapters, messages: messages, title: "B", atTurn: 4, priorTitle: "A")
        #expect(ChapterBook.opened(&chapters, messages: messages, title: "C", atTurn: 3, priorTitle: "B") == 1)
        #expect(chapters.last?.turn == 5)
        #expect(ChapterBook.opened(&chapters, messages: messages, title: "D", atTurn: 2, priorTitle: "C") == 2)
        #expect(chapters.last?.turn == 6)
        #expect(ChapterBook.opened(&chapters, messages: messages, title: "E", atTurn: 6, priorTitle: "D") == nil)
    }

    @Test func aGistLandsOnTheChapterItWasWrittenForEvenAfterARecount() {
        var chapters = [
            Chapter(title: "A", turn: 1, messageID: nil, startedAt: Date(timeIntervalSince1970: 100), gist: nil, namedBy: .model),
            Chapter(title: "B", turn: 4, messageID: nil, startedAt: Date(timeIntervalSince1970: 400), gist: nil, namedBy: .model),
        ]
        let written = chapters[0]
        chapters[0].turn = 2
        #expect(ChapterBook.summed(&chapters, chapter: written, gist: "Did A."))
        #expect(chapters[0].gist == "Did A.")
        #expect(!ChapterBook.summed(&chapters, chapter: written, gist: "Again."))
    }

    @Test func readingTheTranscriptBackRecountsEachChapterByWhenItBegan() {
        let live = [
            prompt("u-x1", "start", at: 100), answer("a-x1", "ok", at: 110),
            prompt("u-x2", "/usage", at: 200), answer("a-x2", "usage table", at: 201),
            prompt("u-x3", "new topic", at: 300), answer("a-x3", "ok", at: 310),
        ]
        var chapters: [Chapter] = []
        _ = ChapterBook.opened(&chapters, messages: live, title: "New topic", atTurn: 3, priorTitle: "Start")
        #expect(chapters.map(\.turn) == [1, 3])
        let disk = [
            prompt("u-m1", "start", at: 101), answer("a-r1", "ok", at: 110),
            prompt("u-m3", "new topic", at: 304), answer("a-r3", "ok", at: 310),
        ]
        let recounted = ChapterBook.reanchored(chapters, messages: disk)
        #expect(recounted.map(\.turn) == [1, 2])
        #expect(recounted.map(\.messageID) == ["u-m1", "u-m3"])
        #expect(recounted[1].startedAt == chapters[1].startedAt)
        let far = disk.map { message in
            var moved = message
            moved.createdAt = message.createdAt.addingTimeInterval(3600)
            return moved
        }
        #expect(ChapterBook.reanchored(chapters, messages: far).map(\.turn) == [1, 3])
    }

    @Test func servedChaptersNameTheMessagesAsTheyStandNow() {
        let chapters = [
            Chapter(title: "A", turn: 1, messageID: "u-old1", startedAt: Date(), gist: nil, namedBy: .kept),
            Chapter(title: "B", turn: 3, messageID: "u-old3", startedAt: Date(), gist: nil, namedBy: .model),
        ]
        let served = ChapterBook.resolved(chapters, messages: conversation(4))
        #expect(served.map(\.messageID) == ["u-1", "u-3"])
    }

    @Test func aBackfillKeepsTheConversationsOwnNameOnTheLastChapter() throws {
        let messages = conversation(8)
        let shown = ChapterBook.backfillPrompts(messages)
        let segments = [
            Titler.Segment(start: 1, title: "Setup", gist: "Set it up."),
            Titler.Segment(start: 5, title: "Polish", gist: nil),
        ]
        let chapters = try #require(
            ChapterBook.backfilled(
                [], messages: messages, title: "Pinned name", customTitle: true, segments: segments,
                shown: shown))
        #expect(chapters.map(\.title) == ["Setup", "Pinned name"])
        #expect(chapters.map(\.turn) == [1, 5])
        #expect(chapters.map(\.namedBy) == [.model, .person])
        #expect(chapters[0].gist == "Set it up.")
        #expect(
            ChapterBook.backfilled(
                chapters, messages: messages, title: "x", customTitle: false, segments: segments,
                shown: shown) == nil)
    }

    @Test func aForkCarriesTheChaptersAndNamesTheOneItGoesOn() {
        let chapters = [
            Chapter(title: "A", turn: 1, messageID: nil, startedAt: Date(), gist: "Did A.", namedBy: .model),
            Chapter(title: "B", turn: 3, messageID: nil, startedAt: Date(), gist: "Did B.", namedBy: .model),
        ]
        let forked = ChapterBook.forked(chapters, title: "B (fork)")
        #expect(forked.map(\.title) == ["A", "B (fork)"])
        #expect(forked[1].namedBy == .fork && forked[1].gist == nil)
        #expect(forked[0].gist == "Did A.")
    }
}

/// A stand-in that is both engines a session uses: `omp --mode rpc` acknowledging every request,
/// and `omp -p`, which answers with the first line of `replies` and drops it, so a test lines up
/// the title, the look and the gist it expects to be asked for, in order.
private struct TwoFacedOmp {
    let root: String
    let binary: String
    let replies: String

    init() throws {
        root = makeTempDir("chapters-live")
        binary = root + "/omp"
        replies = root + "/replies"
        let body = """
            #!/bin/sh
            if [ "$1" = "-p" ]; then
              head -n 1 "\(replies)" | tr '~' '\n'
              tail -n +2 "\(replies)" > "\(replies).next" && mv "\(replies).next" "\(replies)"
              exit 0
            fi
            echo '{"type":"ready","supportedProtocolVersions":[1]}'
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
              cmd=$(printf '%s' "$line" | sed -n 's/.*"type":"\\([^"]*\\)".*/\\1/p')
              printf '{"type":"response","id":"%s","command":"%s","success":true,"data":{}}\\n' "$id" "$cmd"
            done
            """
        try writeExecutable(body, to: binary)
    }

    func lineUp(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(toFile: replies, atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }
}

private func turn(_ session: OmpSession, saying words: String, answer: String) async throws {
    _ = await session.enqueue(
        EnqueueRequest(id: UUID().uuidString, text: words, kind: nil, model: nil, effort: nil, attachments: nil))
    await session.handleOmpEvent(.object(["type": .string("agent_start")]))
    await session.handleOmpEvent(
        .object([
            "type": .string("message_start"),
            "message": .object(["role": .string("assistant")]),
        ]))
    await session.handleOmpEvent(
        .object([
            "type": .string("message_update"),
            "assistantMessageEvent": .object(["type": .string("text_delta"), "delta": .string(answer)]),
        ]))
    await session.handleOmpEvent(
        .object([
            "type": .string("message_end"),
            "message": .object(["role": .string("assistant"), "stopReason": .string("stop")]),
        ]))
    await session.handleOmpEvent(.object(["type": .string("agent_end")]))
}

@Suite(.serialized) struct ChapterSessionTests {
    @Test func aLiveConversationIsNamedLookedAtAndChaptered() async throws {
        let fake = try TwoFacedOmp()
        defer { fake.cleanUp() }
        try fake.lineUp([
            "Bridge setup",
            "<think>moved at the second~</think>~MOVED 2: Release notes",
            "Set up the bridge and its config.",
        ])
        let session = OmpSession(
            title: "New chat", directory: fake.root, model: "", effort: "medium",
            config: config(fake.root, omp: fake.binary), hub: Hub(), quietRegistry: QuietRegistry())

        try await turn(session, saying: "set up the bridge", answer: "done")
        #expect(await session.chapterRecord().chapters?.first?.namedBy == .prompt)
        #expect(await settle(session, past: 1))
        #expect(await session.titleText() == "Bridge setup")
        #expect(await session.chapterRecord().titledAtTurn == 1)

        try await turn(session, saying: "and the config", answer: "configured")
        try await turn(session, saying: "now write the release notes", answer: "drafted")
        #expect(await session.chapterRecord().revision == 2)
        try await turn(session, saying: "shorter please", answer: "shortened")
        #expect(await settle(session, past: 2))
        #expect(await settle(session, past: 3))

        let record = await session.chapterRecord()
        #expect(await session.titleText() == "Release notes")
        #expect(record.titledAtTurn == 4)
        #expect(record.chapters?.map(\.title) == ["Bridge setup", "Release notes"])
        #expect(record.chapters?.map(\.turn) == [1, 3])
        #expect(record.chapters?.first?.gist == "Set up the bridge and its config.")
        #expect(record.chapters?.last?.gist == nil)
    }

    @Test func anOlderConversationIsSplitOnceWhenItIsFirstRead() async throws {
        let dir = makeTempDir("chapters-backfill")
        let omp = try fakeOmp(
            in: dir,
            reply: "<think>splitting</think>\n1 | Bridge setup | Set up the bridge.\n4 | Test fixes |")
        let file = try transcript(dir, prompts: 6)
        let session = OmpSession(
            title: "Test fixes now", directory: dir, model: "", effort: "medium", ompSessionFile: file,
            config: config(dir, omp: omp), hub: Hub(), quietRegistry: QuietRegistry(),
            namedByModel: true)
        await session.adoptExternally(loaded: TranscriptLoader.load(sessionFile: file), ompID: nil)
        #expect(await session.chaptersSnapshot().chapters == nil)
        await session.backfillChaptersIfNeeded()
        #expect(await settle(session, past: 0))
        let served = await session.chaptersSnapshot()
        #expect(served.revision == 1)
        #expect(served.chapters?.map(\.title) == ["Bridge setup", "Test fixes now"])
        #expect(served.chapters?.map(\.messageID) == ["u-m1", "u-m4"])
        #expect(served.chapters?.first?.gist == "Set up the bridge.")
        await session.backfillChaptersIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await session.chapterRecord().revision == 1)

        try await session.clear()
        let cleared = await session.chaptersSnapshot()
        #expect(cleared.revision == 2)
        #expect(cleared.chapters?.isEmpty == true)
        #expect(await session.autoTitledValue() == false)
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func aShortConversationIsNotSplit() async throws {
        let dir = makeTempDir("chapters-short")
        let omp = try fakeOmp(in: dir, reply: "1 | One | Did one.\n2 | Two |")
        let file = try transcript(dir, prompts: 5)
        let session = OmpSession(
            title: "Short", directory: dir, model: "", effort: "medium", ompSessionFile: file,
            config: config(dir, omp: omp), hub: Hub(), quietRegistry: QuietRegistry())
        await session.adoptExternally(loaded: TranscriptLoader.load(sessionFile: file), ompID: nil)
        await session.backfillChaptersIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await session.chapterRecord().revision == nil)
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func chaptersSurviveARestartAndAFork() async throws {
        let dir = makeTempDir("chapters-restart")
        let omp = try fakeOmp(in: dir, reply: "KEEP")
        let file = try transcript(dir, prompts: 6)
        let settings = config(dir, omp: omp)
        let first = App(config: settings)
        let adopted = await first.adopt(file: file, ompID: "s-chapters")
        let kept = [
            Chapter(
                title: "Bridge setup", turn: 1, messageID: nil,
                startedAt: Date(timeIntervalSince1970: 1_794_295_660), gist: "Set up the bridge.",
                namedBy: .model),
            Chapter(
                title: "Test fixes", turn: 4, messageID: nil,
                startedAt: Date(timeIntervalSince1970: 1_794_295_840), gist: nil, namedBy: .model),
        ]
        await adopted.restoreChapters(kept, revision: 3, titledAtTurn: 6)
        await first.flushAll()

        let second = App(config: settings)
        await second.prepare()
        let back = try #require(await second.liveSession(id: adopted.id))
        let record = await back.chapterRecord()
        #expect(record.revision == 3)
        #expect(record.titledAtTurn == 6)
        #expect(record.chapters?.map(\.turn) == [1, 4])
        #expect(await back.chaptersSnapshot().chapters?.map(\.messageID) == ["u-m1", "u-m4"])

        let fork = try await second.forkSession(id: adopted.id)
        let forked = await fork.chapterRecord()
        #expect(forked.chapters?.map(\.namedBy) == [.model, .fork])
        #expect(forked.chapters?.last?.title == (await back.titleText()) + " (fork)")
        #expect(forked.revision == 3)
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func theStatusAndAChapterFrameSpeakClaudeBridgesShape() throws {
        let chapter = Chapter(
            title: "A", turn: 1, messageID: "u-1", startedAt: Date(timeIntervalSince1970: 0),
            gist: nil, namedBy: .prompt)
        let frame = String(
            data: try WireCoding.encoder.encode(BridgeEvent.chapters([chapter], revision: 4)),
            encoding: .utf8) ?? ""
        #expect(frame.contains(#""type":"chapters""#))
        #expect(frame.contains(#""revision":4"#))
        #expect(frame.contains(#""namedBy":"prompt""#))
        let decoded = try WireCoding.decoder.decode(BridgeEvent.self, from: Data(frame.utf8))
        guard case .chapters(let list, let revision) = decoded else {
            Issue.record("not a chapters frame")
            return
        }
        #expect(list == [chapter] && revision == 4)
    }
}

/// Runs the looks against a real oh-my-pi and model, on a real transcript, when
/// `OMP_TEST_BIN`, `OMP_TEST_MODEL` and `OMP_TEST_TRANSCRIPT` are set; prints what came back so a
/// person can judge it.
@Suite struct LiveChapterTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test func aRealEngineSplitsAndLooksInTheGrammarAsked() async throws {
        guard let binary = Self.environment["OMP_TEST_BIN"], let model = Self.environment["OMP_TEST_MODEL"],
            let file = Self.environment["OMP_TEST_TRANSCRIPT"]
        else { return }
        let cwd = makeTempDir("chapters-real")
        let messages = TranscriptLoader.load(sessionFile: file).messages
        let shown = ChapterBook.backfillPrompts(messages)
        let segments = await Titler.segments(
            binary: binary, model: model, cwd: cwd, current: "Untitled",
            prompts: shown.map { ChapterBook.text(of: $0.message) })
        for segment in segments ?? [] {
            print("SPLIT \(segment.start) (turn \(shown[segment.start - 1].turn)) | \(segment.title) | \(segment.gist ?? "-")")
        }
        #expect(segments != nil)
        let turn = ChapterBook.prompts(in: messages).count
        let recent = ChapterBook.recent(messages, since: max(0, turn - 4), through: turn)
        let answer = messages.last { $0.role == .assistant && !ChapterBook.text(of: $0).isEmpty }
            .map(ChapterBook.text(of:)) ?? ""
        let verdict = await Titler.revised(
            binary: binary, model: model, cwd: cwd, current: segments?.last?.title ?? "Untitled",
            prompts: recent.map { ChapterBook.text(of: $0.message) }, assistant: answer)
        print("LOOK \(verdict)")
        #expect(verdict != .failed)
        if let first = segments?.first, segments?.count ?? 0 > 1,
            let input = ChapterBook.gistInput(
                [
                    Chapter(title: first.title, turn: shown[0].turn, messageID: nil, startedAt: Date(), gist: nil, namedBy: .model),
                    Chapter(title: "next", turn: shown[segments![1].start - 1].turn, messageID: nil, startedAt: Date(), gist: nil, namedBy: .model),
                ], messages: messages, closed: 0)
        {
            let gist = await Titler.gist(
                binary: binary, model: model, cwd: cwd, title: first.title, prompts: input.prompts,
                answer: input.answer)
            print("GIST \(gist ?? "nil")")
            #expect(gist != nil)
        }
        try? FileManager.default.removeItem(atPath: cwd)
    }
}
