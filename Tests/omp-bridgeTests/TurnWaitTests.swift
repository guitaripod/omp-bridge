import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import Testing

@testable import omp_bridge

/// A `ResponseBodyWriter` double that keeps every chunk `TurnWaitEngine.run` writes, so a test can
/// read back the heartbeat newlines and the final JSON object the same way a client would.
private struct CollectingWriter: ResponseBodyWriter {
    final class Box: @unchecked Sendable {
        var chunks: [ByteBuffer] = []
        var finished = false
    }

    let box = Box()

    mutating func write(_ buffer: ByteBuffer) async throws {
        box.chunks.append(buffer)
    }

    mutating func write(contentsOf buffers: some Sequence<ByteBuffer>) async throws {
        box.chunks.append(contentsOf: buffers)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        box.finished = true
    }
}

@Suite struct TurnWaitTests {
    private func makeSession(hub: Hub = Hub()) -> OmpSession {
        let dir = makeTempDir("turnwait")
        let config = Config(
            port: 0, bind: "", password: "", workdir: dir, ompBin: "/bin/false",
            storePath: dir + "/sessions.json",
            stateDir: dir, srcPath: nil, defaultModel: nil, defaultEffort: "medium", titleModel: nil,
            waitMax: 10800)
        return OmpSession(
            title: "Test", directory: dir, model: "", effort: "medium",
            config: config, hub: hub, quietRegistry: QuietRegistry())
    }

    private func decode(_ box: CollectingWriter.Box) -> TurnWait {
        let data = box.chunks.reduce(Data()) { $0 + Data($1.readableBytesView) }
        return try! WireCoding.decoder.decode(TurnWait.self, from: data)
    }

    private func heartbeatCount(_ box: CollectingWriter.Box) -> Int {
        box.chunks.filter { String(buffer: $0) == "\n" }.count
    }

    @Test func idleSessionAnswersAtOnceWithoutWaiting() async throws {
        let session = makeSession()
        var writer: any ResponseBodyWriter = CollectingWriter()
        let collecting = writer as! CollectingWriter
        try await TurnWaitEngine.run(session: session, maxWait: 10, writer: &writer)
        let wait = decode(collecting.box)
        #expect(wait.state == .ended)
        #expect(wait.waited == false)
        #expect(wait.ending == nil)
        #expect(collecting.box.finished)
        #expect(heartbeatCount(collecting.box) == 1)
    }

    @Test func turnEndResolvesWithItsEnding() async throws {
        let session = makeSession()
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        #expect(await session.isRunningValue())
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await session.handleOmpEvent(
                .object([
                    "type": .string("message_start"),
                    "message": .object(["role": .string("assistant"), "model": .string("m1")]),
                ]))
            await session.handleOmpEvent(
                .object([
                    "type": .string("message_update"),
                    "assistantMessageEvent": .object([
                        "type": .string("text_delta"), "delta": .string("done"),
                    ]),
                ]))
            await session.handleOmpEvent(.object(["type": .string("agent_end")]))
        }
        var writer: any ResponseBodyWriter = CollectingWriter()
        let collecting = writer as! CollectingWriter
        try await TurnWaitEngine.run(session: session, maxWait: 10, writer: &writer)
        let wait = decode(collecting.box)
        #expect(wait.state == .ended)
        #expect(wait.waited == true)
        #expect(wait.ending == .finished)
        #expect(wait.toolCount == 0)
        #expect(!(await session.isRunningValue()))
    }

    @Test func toolFreeTurnReportsZeroNotOne() async throws {
        let session = makeSession()
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        await session.handleOmpEvent(.object(["type": .string("agent_end")]))
        let wait = await TurnWaitEngine.resolved(for: session, waited: false)
        #expect(wait?.toolCount == 0)
    }

    @Test func turnWithCallsReportsItsRealCount() async throws {
        let session = makeSession()
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        await session.handleOmpEvent(.object(["type": .string("turn_start")]))
        await session.handleOmpEvent(.object(["type": .string("turn_start")]))
        await session.handleOmpEvent(.object(["type": .string("agent_end")]))
        let wait = await TurnWaitEngine.resolved(for: session, waited: false)
        #expect(wait?.toolCount == 2)
    }

    @Test func pendingQuestionResolvesNeedsYou() async throws {
        let session = makeSession()
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await session.handleOmpEvent(
                .object([
                    "type": .string("extension_ui_request"),
                    "id": .string("ask-1"),
                    "method": .string("confirm"),
                    "title": .string("Proceed?"),
                ]))
        }
        var writer: any ResponseBodyWriter = CollectingWriter()
        let collecting = writer as! CollectingWriter
        try await TurnWaitEngine.run(session: session, maxWait: 10, writer: &writer)
        let wait = decode(collecting.box)
        #expect(wait.state == .needsYou)
        #expect(wait.ending == .question)
        #expect(wait.waited == true)
    }

    @Test func capAnswersRunningWhenNothingSettles() async throws {
        let session = makeSession()
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        var writer: any ResponseBodyWriter = CollectingWriter()
        let collecting = writer as! CollectingWriter
        try await TurnWaitEngine.run(session: session, maxWait: 0.05, writer: &writer)
        let wait = decode(collecting.box)
        #expect(wait.state == .running)
        #expect(wait.waited == true)
        #expect(wait.ending == nil)
    }

    @Test func processFailureResolvesAsFailed() async throws {
        let session = makeSession()
        await session.handleOmpEvent(.object(["type": .string("agent_start")]))
        await session.handleOmpEvent(.object(["type": .string("process_exited")]))
        #expect(await TurnWaitEngine.resolved(for: session, waited: false)?.ending == .failed)
    }

    @Test func recoveredInterruptionResolvesAsInterrupted() async throws {
        let session = makeSession()
        await session.markInterrupted(toolCount: 3, endedAt: Date())
        let wait = await TurnWaitEngine.resolved(for: session, waited: false)
        #expect(wait?.ending == .interrupted)
        #expect(wait?.toolCount == 3)
    }

    @Test func turnWaitEncodingOmitsUnknownFields() throws {
        let wait = TurnWait(state: .ended, waited: false)
        let data = try WireCoding.encoder.encode(wait)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["state", "waited"])
    }

    @Test func turnWaitEncodesEveryDocumentedField() throws {
        let wait = TurnWait(
            state: .ended, waited: true, ending: .finished, title: "Session title", toolCount: 4,
            duration: 192.4, lastMessageID: "m-1", endedAt: Date(timeIntervalSince1970: 0))
        let data = try WireCoding.encoder.encode(wait)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(
            Set(object?.keys.map { $0 } ?? [])
                == ["state", "waited", "ending", "title", "toolCount", "duration", "lastMessageID", "endedAt"])
    }
}
