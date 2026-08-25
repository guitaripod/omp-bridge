import Foundation
import Testing

@testable import omp_bridge

@Suite struct HubTests {
    @Test func replayAndResetSemantics() async {
        let hub = Hub()
        for index in 1...5 {
            await hub.publish(.listRemove(id: "s\(index)"))
        }
        let fresh = await hub.attach(sinceEpoch: nil, sinceSeq: nil)
        #expect(fresh.replay.isEmpty)
        #expect(!fresh.tooOld)
        #expect(fresh.headSeq == 5)

        let cursor = await hub.attach(sinceEpoch: hub.epoch, sinceSeq: 3)
        #expect(cursor.replay.count == 2)
        #expect(cursor.replay.first?.seq == 4)

        let stale = await hub.attach(sinceEpoch: "other-epoch", sinceSeq: 3)
        #expect(stale.tooOld)
        #expect(stale.replay.isEmpty)
    }

    @Test func subscribersReceivePublishedFrames() async {
        let hub = Hub()
        let attachment = await hub.attach(sinceEpoch: nil, sinceSeq: nil)
        await hub.publish(.listUpsert(
            SessionSummary(
                id: "x", title: "t", directory: nil, model: "", effort: "",
                createdAt: Date(), updatedAt: Date())))
        var received: HubFrame?
        for await frame in attachment.stream {
            received = frame
            break
        }
        #expect(received != nil)
    }
}

@Suite struct StoreTests {
    @Test func persistsAndHides() async throws {
        let dir = makeTempDir("store")
        let store = SessionStore(path: dir + "/sessions.json")
        let counts = TokenCounts(input: 10, output: 5)
        await store.upsert(
            SessionRecord(
                id: "a", title: "A", directory: "/tmp", model: "m", effort: "medium",
                createdAt: Date(), updatedAt: Date(), ompSessionID: "omp-1",
                ompSessionFile: "/tmp/none.jsonl", customTitle: true, autoTitled: false,
                turns: [TurnRecord(at: Date(), seconds: 1, model: "m", calls: 1, tokens: counts, costUSD: 0.1, prompt: "p")],
                totalCostUSD: 0.1, totalTokens: counts, lastCostUSD: 0.1, lastTokens: 15,
                interruption: nil, autoResume: nil))
        await store.flush()

        let reloaded = SessionStore(path: dir + "/sessions.json")
        let record = await reloaded.record(for: "a")
        #expect(record?.title == "A")
        #expect(record?.turns.first?.prompt == "p")

        _ = await reloaded.remove("a")
        #expect(await reloaded.isHidden("omp-1"))
        #expect(await reloaded.record(for: "a") == nil)
    }
}
