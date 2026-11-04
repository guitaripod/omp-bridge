import Foundation
import Testing

@testable import omp_bridge

/// What oh-my-pi says about a turn beyond its words — sub-agents, retries, a long tool's output —
/// reaching a client in claude-bridge's shapes.
@Suite struct EngineSignalsTests {
    private func makeSession(hub: Hub) -> OmpSession {
        let dir = makeTempDir("signals")
        let config = Config(
            port: 0, bind: "", password: "", workdir: dir, ompBin: "/bin/false",
            storePath: dir + "/sessions.json",
            stateDir: dir, srcPath: nil, defaultModel: nil, defaultEffort: "medium", titleModel: nil,
            waitMax: 10800)
        return OmpSession(
            title: "Test", directory: dir, model: "", effort: "medium",
            config: config, hub: hub, quietRegistry: QuietRegistry())
    }

    private func frames(_ hub: Hub) async -> [HubEvent] {
        await hub.attach(sinceEpoch: hub.epoch, sinceSeq: 0).replay.map(\.event)
    }

    private func lifecycle(_ id: String, _ status: String) -> JSONValue {
        .object([
            "type": .string("subagent_lifecycle"),
            "payload": .object([
                "id": .string(id), "agent": .string("explore"), "status": .string(status),
                "index": .number(0), "description": .string("Map the parser"),
                "parentToolCallId": .string("call-7"),
            ]),
        ])
    }

    @Test func subAgentsAreReadFromTheirPayloadAndAnnounced() async {
        let hub = Hub()
        let session = makeSession(hub: hub)
        await session.handleOmpEvent(lifecycle("sa-1", "started"))
        await session.handleOmpEvent(
            .object([
                "type": .string("subagent_progress"),
                "payload": .object([
                    "index": .number(0), "agent": .string("explore"), "task": .string("Map the parser"),
                    "progress": .object([
                        "id": .string("sa-1"), "status": .string("running"),
                        "toolCount": .number(4), "currentTool": .string("grep"),
                    ]),
                ]),
            ]))
        let live = await session.subagentSummaries()
        #expect(live.count == 1)
        #expect(live.first?.title == "Map the parser")
        #expect(live.first?.agentType == "explore")
        #expect(live.first?.toolUseID == "call-7")
        #expect(live.first?.active == true)
        #expect(live.first?.toolCount == 4)
        #expect(live.first?.currentTool == "grep")

        await session.handleOmpEvent(lifecycle("sa-1", "completed"))
        let done = await session.subagentSummaries()
        #expect(done.first?.active == false)
        #expect(done.first?.completed == true)
        #expect(done.first?.currentTool == nil)

        let announced = await frames(hub).compactMap { event -> [SubagentSummary]? in
            if case .agents(_, let agents) = event { return agents }
            return nil
        }
        #expect(announced.first?.first?.active == true)
        #expect(announced.last?.first?.active == false)
    }
}
