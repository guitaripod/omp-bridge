import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import Testing

@testable import omp_bridge

/// A player reads one file on a ticket, a range at a time, and nothing else.
@Suite("File tickets")
struct FileTicketsTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_000_000)
        func read() -> Date { lock.withLock { now } }
        func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    }

    @Test("a ticket admits the file it was issued for")
    func admitsItsFile() async {
        let tickets = FileTickets()
        let ticket = await tickets.issue(path: "/home/me/clip.mp4")
        #expect(ticket.count == 64)
        #expect(await tickets.path(for: ticket) == "/home/me/clip.mp4")
        #expect(await tickets.path(for: "0123") == nil)
    }

    @Test("one file named again keeps its one ticket")
    func reusesTheLiveTicket() async {
        let tickets = FileTickets()
        let first = await tickets.issue(path: "/a.mp4")
        let again = await tickets.issue(path: "/a.mp4")
        let other = await tickets.issue(path: "/b.mp4")
        #expect(first == again)
        #expect(first != other)
        #expect(await tickets.count == 2)
    }

    @Test("a ticket in use never runs out, an idle one does")
    func slidesWhileRead() async {
        let clock = Clock()
        let tickets = FileTickets(lifetime: 100, clock: { clock.read() })
        let ticket = await tickets.issue(path: "/film.mkv")
        for _ in 0..<5 {
            clock.advance(80)
            #expect(await tickets.path(for: ticket) == "/film.mkv")
        }
        clock.advance(101)
        #expect(await tickets.path(for: ticket) == nil)
        #expect(await tickets.count == 0)
    }

    @Test("past capacity the ticket closest to running out goes first")
    func evictsTheOldest() async {
        let clock = Clock()
        let tickets = FileTickets(lifetime: 1000, capacity: 2, clock: { clock.read() })
        let oldest = await tickets.issue(path: "/1")
        clock.advance(1)
        let middle = await tickets.issue(path: "/2")
        clock.advance(1)
        let newest = await tickets.issue(path: "/3")
        #expect(await tickets.path(for: oldest) == nil)
        #expect(await tickets.path(for: middle) == "/2")
        #expect(await tickets.path(for: newest) == "/3")
    }

    @Test("ranges are read the way players send them")
    func parsesRanges() {
        #expect(ByteRange.parse(nil, size: 100) == .whole)
        #expect(ByteRange.parse("bytes=0-1", size: 100) == .part(lower: 0, upper: 1))
        #expect(ByteRange.parse("bytes=10-", size: 100) == .part(lower: 10, upper: 99))
        #expect(ByteRange.parse("bytes=-30", size: 100) == .part(lower: 70, upper: 99))
        #expect(ByteRange.parse("bytes=-300", size: 100) == .part(lower: 0, upper: 99))
        #expect(ByteRange.parse("bytes=90-500", size: 100) == .part(lower: 90, upper: 99))
        #expect(ByteRange.parse("bytes=100-", size: 100) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=0-1,5-9", size: 100) == .whole)
        #expect(ByteRange.parse("bytes=9-3", size: 100) == .whole)
        #expect(ByteRange.parse("items=0-1", size: 100) == .whole)
    }

    @Test("a ticket opens only a read of the raw route")
    func admitsOnlyRawReads() {
        func request(_ method: HTTPRequest.Method, _ path: String) -> Request {
            Request(
                head: HTTPRequest(method: method, scheme: "http", authority: "bridge", path: path),
                body: .init(buffer: ByteBuffer()))
        }
        #expect(BasicAuthMiddleware<BasicRequestContext>.ticket(request(.get, "/files/raw?ticket=abc")) == "abc")
        #expect(BasicAuthMiddleware<BasicRequestContext>.ticket(request(.get, "/files/raw?path=/etc/hosts")) == nil)
        #expect(BasicAuthMiddleware<BasicRequestContext>.ticket(request(.post, "/files/raw?ticket=abc")) == nil)
        #expect(BasicAuthMiddleware<BasicRequestContext>.ticket(request(.get, "/sessions?ticket=abc")) == nil)
        #expect(BasicAuthMiddleware<BasicRequestContext>.ticket(request(.get, "/files/content?ticket=abc")) == nil)
    }

    @Test("the client note tells the agent how to show a video or a song")
    func noteNamesPlayers() {
        #expect(ClientNote.text.contains("absolute path"))
        #expect(ClientNote.text.count < 800)
    }
}
