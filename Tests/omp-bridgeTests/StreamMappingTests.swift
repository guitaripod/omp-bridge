import Foundation
import Testing

@testable import omp_bridge

@Suite struct StreamMappingTests {
    private func makeSession(hub: Hub) -> (OmpSession, Config) {
        let dir = makeTempDir("mapping")
        let config = Config(
            port: 0, bind: "", password: "", workdir: dir, ompBin: "/bin/false",
            storePath: dir + "/sessions.json",
            stateDir: dir, srcPath: nil, defaultModel: nil, defaultEffort: "medium")
        let session = OmpSession(
            title: "Test", directory: dir, model: "", effort: "medium",
            config: config, hub: hub, quietRegistry: QuietRegistry())
        return (session, config)
    }

    private func sessionEvents(_ hub: Hub) async -> [BridgeEvent] {
        let attachment = await hub.attach(sinceEpoch: hub.epoch, sinceSeq: 0)
        return attachment.replay.compactMap { frame in
            if case .session(_, let event) = frame.event { return event }
            return nil
        }
    }

    @Test func assistantShellPrecedesDeltas() async {
        let hub = Hub()
        let (session, _) = makeSession(hub: hub)
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_start"),
                "message": .object(["role": .string("assistant"), "model": .string("m1")]),
            ]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_update"),
                "assistantMessageEvent": .object([
                    "type": .string("text_delta"), "delta": .string("Hel"),
                ]),
            ]))

        let events = await sessionEvents(hub)
        guard events.count >= 2 else {
            Issue.record("expected shell and delta, got \(events.count) events")
            return
        }
        guard case .messageUpserted(let shell) = events[0] else {
            Issue.record("no assistant shell before the first delta")
            return
        }
        #expect(shell.role == .assistant)
        guard case .partTextDelta(let messageID, let delta) = events[1] else {
            Issue.record("first delta frame missing")
            return
        }
        #expect(messageID == shell.id)
        #expect(delta == "Hel")
    }

    @Test func reasoningNeverRidesTheTextChannel() async {
        let hub = Hub()
        let (session, _) = makeSession(hub: hub)
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_start"),
                "message": .object(["role": .string("assistant")]),
            ]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_update"),
                "assistantMessageEvent": .object([
                    "type": .string("thinking_delta"), "delta": .string("pondering"),
                ]),
            ]))

        let events = await sessionEvents(hub)
        for event in events {
            if case .partTextDelta(_, let delta) = event {
                #expect(!delta.contains("pondering"), "thinking leaked into the delta channel")
            }
        }
        let snapshots = events.compactMap { event -> Message? in
            if case .messageUpserted(let message) = event { return message }
            return nil
        }
        let reasoned = snapshots.contains { message in
            message.parts.contains { part in
                if case .reasoning(let text) = part { return text == "pondering" }
                return false
            }
        }
        #expect(reasoned, "reasoning never surfaced in a live snapshot")
    }

    @Test func toolCompletionIsPublishedBeforeMessageEnd() async {
        let hub = Hub()
        let (session, _) = makeSession(hub: hub)
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_start"),
                "message": .object(["role": .string("assistant")]),
            ]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_update"),
                "assistantMessageEvent": .object(["type": .string("toolcall_start")]),
            ]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_update"),
                "assistantMessageEvent": .object([
                    "type": .string("toolcall_end"),
                    "toolCall": .object([
                        "id": .string("tc-1"), "name": .string("bash"),
                        "arguments": .object(["command": .string("true")]),
                    ]),
                ]),
            ]))
        await session.handleOmpEvent(
            .object([
                "type": .string("tool_execution_start"),
                "toolCallId": .string("tc-1"), "toolName": .string("bash"),
            ]))
        await session.handleOmpEvent(
            .object([
                "type": .string("tool_execution_end"),
                "toolCallId": .string("tc-1"), "isError": .bool(false),
                "result": .object([
                    "content": .array([.object(["text": .string("done")])])
                ]),
            ]))

        var sawCompleted = false
        for event in await sessionEvents(hub) {
            if case .toolUpserted(_, let call) = event, call.id == "tc-1",
                call.status == .completed
            {
                sawCompleted = true
                #expect(call.output == "done")
            }
        }
        #expect(sawCompleted, "tool completion never streamed")
    }

    @Test func messageEndAssemblesAndSnapshotIncludesLiveMessage() async {
        let hub = Hub()
        let (session, _) = makeSession(hub: hub)
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_start"),
                "message": .object(["role": .string("assistant")]),
            ]))
        await session.handleOmpEvent(
            .object([
                "type": .string("message_update"),
                "assistantMessageEvent": .object([
                    "type": .string("text_delta"), "delta": .string("Answer"),
                ]),
            ]))

        let live = await session.snapshotMessages()
        #expect(live.count == 1, "mid-turn snapshot must carry the live message")
        #expect(live.first?.role == .assistant)

        await session.handleOmpEvent(
            .object([
                "type": .string("message_end"),
                "message": .object([
                    "role": .string("assistant"),
                    "usage": .object([
                        "input": .number(10), "output": .number(5),
                        "cost": .object(["total": .number(0.02)]),
                    ]),
                ]),
            ]))
        await session.handleOmpEvent(
            .object(["type": .string("agent_end"), "isTerminal": .bool(true)]))

        let settled = await session.snapshotMessages()
        #expect(settled.count == 1)
        #expect(settled.first?.costUSD == 0.02)
        let events = await sessionEvents(hub)
        let finals = events.compactMap { event -> Message? in
            if case .messageUpserted(let message) = event { return message }
            return nil
        }
        #expect(finals.last?.costUSD == 0.02)
    }
}
