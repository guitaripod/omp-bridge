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

    @Test func derivedTitle() {
        #expect(OmpSession.derivedTitle(from: "Fix the bug") == "Fix the bug")
        #expect(OmpSession.derivedTitle(from: String(repeating: "x", count: 80)).count == 48)
        #expect(OmpSession.derivedTitle(from: "") == "New chat")
    }
}
