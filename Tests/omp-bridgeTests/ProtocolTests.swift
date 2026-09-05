import Foundation
import Testing

@testable import omp_bridge

@Suite struct ProtocolTests {
    @Test func lineReaderSplitsLines() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("one\ntwo\npartial".utf8))
        try pipe.fileHandleForWriting.close()
        let reader = LineReader(handle: pipe.fileHandleForReading)
        #expect(reader.nextLine() == "one")
        #expect(reader.nextLine() == "two")
        #expect(reader.nextLine() == "partial")
        #expect(reader.nextLine() == nil)
    }

    @Test func jsonValueRoundTrip() {
        let obj: [String: Any] = [
            "name": "read", "count": 3, "ratio": 1.5, "flag": true, "absent": NSNull(),
            "list": ["a", 2], "nested": ["inner": "value"],
        ]
        let value = JSONValue.from(obj)
        #expect(value["name"]?.stringValue == "read")
        #expect(value["count"]?.intValue == 3)
        #expect(value["ratio"]?.doubleValue == 1.5)
        #expect(value["flag"]?.boolValue == true)
        if case .null? = value["absent"] {} else { Issue.record("expected null") }
        #expect(value["list"]?.arrayValue?.count == 2)
        #expect(value["nested"]?["inner"]?.stringValue == "value")
    }

    @Test func serializeArguments() {
        let arguments = JSONValue.from(["path": "/tmp/x", "limit": 10])
        let serialized = OmpSession.serializeArguments(arguments)
        let reparsed = (try? JSONSerialization.jsonObject(with: Data(serialized.utf8))) as? [String: Any]
        #expect(reparsed?["path"] as? String == "/tmp/x")
        #expect((reparsed?["limit"] as? NSNumber)?.intValue == 10)
        #expect(OmpSession.serializeArguments(nil) == "{}")
    }

    @Test func turnsFromAdoptedTranscript() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let messages = [
            Message(id: "u1", role: .user, parts: [.text("fix it")], createdAt: t0, seconds: nil, model: nil, usage: nil, costUSD: nil),
            Message(id: "a1", role: .assistant, parts: [.tool(ToolCall(id: "c1", name: "read", input: "{}", status: .completed))], createdAt: t0.addingTimeInterval(2), seconds: nil, model: "m", usage: TokenCounts(input: 10, output: 5, cacheRead: 0, cacheWrite5m: 100, cacheWrite1h: 0), costUSD: 0.1),
            Message(id: "a2", role: .assistant, parts: [.text("done")], createdAt: t0.addingTimeInterval(5), seconds: nil, model: "m", usage: TokenCounts(input: 1, output: 2, cacheRead: 100, cacheWrite5m: 0, cacheWrite1h: 0), costUSD: 0.05),
            Message(id: "u2", role: .user, parts: [.text("thanks")], createdAt: t0.addingTimeInterval(9), seconds: nil, model: nil, usage: nil, costUSD: nil),
            Message(id: "a3", role: .assistant, parts: [.text("np")], createdAt: t0.addingTimeInterval(10), seconds: nil, model: "m", usage: TokenCounts(input: 3, output: 1, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0), costUSD: 0.01),
        ]
        let turns = OmpSession.turns(from: messages)
        #expect(turns.count == 2)
        #expect(turns[0].prompt == "fix it")
        #expect(turns[0].calls == 1)
        #expect(turns[0].tokens.total == 218)
        #expect(abs(turns[0].costUSD - 0.15) < 0.0001)
        #expect(turns[0].seconds == 5)
        #expect(turns[1].tokens.total == 4)
        #expect(turns[1].calls == 1)
    }

    @Test func derivedTitle() {
        #expect(OmpSession.derivedTitle(from: "Fix the bug") == "Fix the bug")
        #expect(OmpSession.derivedTitle(from: String(repeating: "x", count: 80)).count == 48)
        #expect(OmpSession.derivedTitle(from: "") == "New chat")
        #expect(OmpSession.isPlaceholderTitle("New chat"))
        #expect(OmpSession.isPlaceholderTitle("  "))
        #expect(!OmpSession.isPlaceholderTitle("Fix the bug"))
    }
}

@Suite struct CommandCatalogTests {
    @Test func ompOriginsFoldOntoBridgeVocabulary() {
        let frame = JSONValue.from([
            ["name": "compact", "description": "Compact", "source": "builtin"],
            ["name": "flyr", "description": "Flights", "input": ["hint": "<route>"], "source": "skill"],
            ["name": "delegate", "source": "extension"],
            ["name": "review", "source": "custom"],
            ["name": "notes", "source": "file"],
            ["name": "linear", "source": "mcp_prompt"],
            ["description": "nameless"],
        ] as [Any])
        let parsed = CommandCatalog.parse(frame.arrayValue ?? [])
        #expect(parsed.map(\.name) == ["compact", "flyr", "delegate", "review", "notes", "linear"])
        #expect(parsed.map(\.source) == ["builtin", "skill", "plugin", "user", "user", "mcp"])
        #expect(parsed[1].argumentHint == "<route>")
        #expect(parsed[1].description == "Flights")
    }
}
