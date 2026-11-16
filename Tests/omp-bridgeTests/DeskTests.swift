import Foundation
import Testing

@testable import omp_bridge

@Suite("A phone holding only this bridge can still tell whether its person is at a desk")
struct DeskTests {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func report(
        _ desk: String = "arch", idle: Int? = 0, locked: Bool = false, leaving: Bool = false,
        looked: [String] = []
    ) -> DeskReportBody {
        DeskReportBody(desk: desk, name: desk, idle: idle, locked: locked, leaving: leaving, looked: looked)
    }

    @Test("A desk is there while it reports, is unlocked and saw input within the device's patience")
    func occupancy() {
        let desks = DeskRegistry()
        desks.record(report(idle: 10), now: at(0))
        #expect(desks.occupied(awayAfter: 120, now: at(0))?.desk == "arch")
        #expect(desks.occupied(awayAfter: 120, now: at(60))?.idle == 70, "idle keeps counting between reports")
        #expect(desks.occupied(awayAfter: 60, now: at(50)) == nil, "the patience ran out")
        #expect(desks.occupied(awayAfter: 600, now: at(89)) != nil)
        #expect(desks.occupied(awayAfter: 600, now: at(90)) == nil, "a silent desk has gone")
        #expect(desks.presence(now: at(90)).desks.isEmpty)

        desks.record(report(idle: 0, locked: true), now: at(100))
        #expect(desks.occupied(awayAfter: 600, now: at(100)) == nil, "a locked screen is someone who left")
        desks.record(report(idle: 0), now: at(110))
        #expect(desks.occupied(awayAfter: 600, now: at(110)) != nil)
        desks.record(report(idle: 0, leaving: true), now: at(111))
        #expect(desks.occupied(awayAfter: 600, now: at(111)) == nil, "a desk going to sleep is gone at once")

        desks.record(report("blind", idle: nil), now: at(120))
        #expect(desks.occupied(awayAfter: 600, now: at(120)) == nil, "a desk that cannot tell is nobody")
        #expect(!desks.record(report("", idle: 0), now: at(120)))
    }

    @Test("A look counts from the moment it was reported, and reports are trimmed")
    func looks() throws {
        let desks = DeskRegistry()
        desks.record(report(looked: ["s1", "", String(repeating: "x", count: 500)]), now: at(5))
        #expect(desks.looked("s1", since: at(5)))
        #expect(!desks.looked("s1", since: at(6)))
        #expect(desks.presence(now: at(5)).looked.keys.sorted() == ["s1"])
        let body = try WireCoding.encoder.encode(desks.presence(now: at(5)))
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(#""heard":0"#))
        #expect(text.contains(#""s1":"2030-03-17T17:46:45Z""#), "dates are ISO-8601 as the Kit reads them")
    }

    @Test("A report from a newer or older desk decodes with quiet defaults")
    func lenientDecode() throws {
        let decoded = try WireCoding.decoder.decode(
            DeskReportBody.self, from: Data(#"{"desk":"d","idle":3,"future":true}"#.utf8))
        #expect(decoded == DeskReportBody(desk: "d", name: "", idle: 3))
        #expect(throws: (any Error).self) {
            try WireCoding.decoder.decode(DeskReportBody.self, from: Data(#"{"idle":3}"#.utf8))
        }
    }

    @Test("The status answer says this bridge keeps desks")
    func status() throws {
        let status = BridgeStatus(
            agent: "omp", model: "", version: "0", authenticated: true, proto: 2, epoch: "e",
            turnWait: 2, marks: 1, queue: 1)
        let text = try #require(String(data: try WireCoding.encoder.encode(status), encoding: .utf8))
        #expect(text.contains(#""presence":1"#))
    }
}
