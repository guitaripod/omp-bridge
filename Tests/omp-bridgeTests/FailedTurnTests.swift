import Foundation
import Testing

@testable import omp_bridge

@Suite struct FailedTurnTests {
    @Test func aFailedAnswerFromTheTranscriptKeepsItsReasonEvenWithNothingSaid() throws {
        let dir = makeTempDir("failed")
        let path = dir + "/\(UUID().uuidString).jsonl"
        let lines = [
            #"{"type":"session","v":3,"id":"s1","cwd":"/tmp/proj"}"#,
            #"{"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"pong?"}],"timestamp":1794295631402}}"#,
            #"{"type":"message","id":"m2","message":{"role":"assistant","content":[],"model":"glm-5.3-flash","provider":"ollama-cloud","stopReason":"error","errorMessage":"HTTP 402 from https://ollama.com/api/chat","timestamp":1794295631500}}"#,
            #"{"type":"message","id":"m3","message":{"role":"user","content":[{"type":"text","text":"again"}],"timestamp":1794295632000}}"#,
            #"{"type":"message","id":"m4","message":{"role":"assistant","content":[],"stopReason":"aborted","errorMessage":"Request was aborted","timestamp":1794295633000}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: path))
        let loaded = TranscriptLoader.load(sessionFile: path)
        let answers = loaded.messages.filter { $0.role == .assistant }
        #expect(answers.count == 1)
        #expect(answers.first?.error == "HTTP 402 from https://ollama.com/api/chat")
        #expect(answers.first?.parts.isEmpty == true)
    }

    @Test func onlyAnErrorStopIsAFailure() {
        #expect(OmpSession.failure(of: .object(["stopReason": .string("error"), "errorMessage": .string(" boom ")])) == "boom")
        #expect(OmpSession.failure(of: .object(["stopReason": .string("aborted"), "errorMessage": .string("x")])) == nil)
        #expect(OmpSession.failure(of: .object(["stopReason": .string("error"), "errorMessage": .string("  ")])) == nil)
        #expect(OmpSession.failure(of: .object(["stopReason": .string("stop")])) == nil)
    }

    @Test func aMessageWithoutAFailureEncodesNoErrorKey() throws {
        let message = Message(
            id: "a1", role: .assistant, parts: [.text("ok")], createdAt: Date(timeIntervalSince1970: 0),
            seconds: nil, model: nil, usage: nil, context: nil, costUSD: nil)
        let json = String(data: try JSONEncoder().encode(message), encoding: .utf8) ?? ""
        #expect(!json.contains("\"error\""))
    }
}
