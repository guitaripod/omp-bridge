import Foundation
import Testing

@testable import omp_bridge

private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment: Date
    init(_ moment: Date) { self.moment = moment }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return moment
    }
    func set(_ value: Date) {
        lock.lock()
        moment = value
        lock.unlock()
    }
}

/// A bridge that keeps conversations as a list of what each was sent.
private actor FakeHost: ScheduleHost {
    var sent: [(id: String, text: String, quiet: Bool)] = []
    var conversations: Set<String> = []

    func scheduledConversationExists(_ id: String) async -> Bool { conversations.contains(id) }

    func makeScheduledConversation(
        title: String, directory: String?, model: String?, effort: String?, scheduleID: String
    ) async -> String {
        let id = "c\(conversations.count + 1)"
        conversations.insert(id)
        return id
    }

    func sendScheduled(_ id: String, text: String, model: String?, effort: String?, quiet: Bool) async
        -> ScheduledSend
    {
        sent.append((id, text, quiet))
        return .started
    }
}

@Suite("omp schedules", .serialized)
struct OmpScheduleTests {
    private func file() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omp-schedules-\(UUID().uuidString).json")
    }

    @Test("Weekdays skip the weekend and every few hours steps from its anchor")
    func rules() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(
            ScheduleRule(kind: "weekdays", hour: 7, minute: 0).next(after: at("2026-11-06T09:00:00Z"), calendar: utc)
                == at("2026-11-09T07:00:00Z"))
        #expect(
            ScheduleRule(kind: "hours", hour: 3, minute: 15, every: 6).next(
                after: at("2026-11-02T10:00:00Z"), calendar: utc) == at("2026-11-02T15:15:00Z"))
    }

    @Test("Runs land in one conversation, and only a run after an answered one is allowed to stay quiet")
    func oneConversation() async throws {
        let host = FakeHost()
        let clock = Clock(at("2026-11-02T06:00:00Z"))
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let scheduler = Scheduler(url: url, store: host, now: { clock.now })
        let made = try await scheduler.create(
            ScheduleDraft(text: "news", rule: ScheduleRule(kind: "daily", hour: 7, minute: 0), timeZone: "UTC"))
        _ = try await scheduler.runNow(made.id)
        await scheduler.turnEnded("c1", TurnEndNote(answer: "three things", failure: nil, stopped: false, quiet: false))
        _ = try await scheduler.runNow(made.id)
        await scheduler.turnEnded("c1", TurnEndNote(answer: "NOTHING NEW", failure: nil, stopped: false, quiet: true))
        let sent = await host.sent
        #expect(sent.map(\.id) == ["c1", "c1"])
        #expect(sent.map(\.quiet) == [false, true])
        let runs = try #require(await scheduler.schedule(made.id)?.runs)
        #expect(runs.map(\.outcome) == ["quiet", "answered"])
        #expect(await scheduler.schedule(made.id)?.next == at("2026-11-02T07:00:00Z"))
    }

    @Test("A machine that was off asks once and counts what it slept through")
    func catchUp() async throws {
        let host = FakeHost()
        let clock = Clock(at("2026-11-02T06:00:00Z"))
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Scheduler(url: url, store: host, now: { clock.now })
        let made = try await first.create(
            ScheduleDraft(text: "build", rule: ScheduleRule(kind: "hours", hour: 0, minute: 0, every: 2), timeZone: "UTC"))
        clock.set(at("2026-11-02T13:30:00Z"))
        let later = Scheduler(url: url, store: host, now: { clock.now })
        await later.catchUp()
        let run = try #require(await later.schedule(made.id)?.runs.first)
        #expect(run.outcome == "caughtUp")
        #expect(run.missed == 3)
        #expect(run.scheduledFor == at("2026-11-02T12:00:00Z"))
        #expect(await host.sent.count == 1)
    }

    @Test("A quiet answer is told apart from an answer that merely starts the same way")
    func wording() {
        #expect(ScheduleWording.saysNothingNew("NOTHING NEW"))
        #expect(ScheduleWording.saysNothingNew("**Nothing new.**"))
        #expect(!ScheduleWording.saysNothingNew("Nothing new on the main branch, but the release slipped to Friday."))
    }
}
