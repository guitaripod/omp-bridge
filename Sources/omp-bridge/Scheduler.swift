import Foundation

/// When a schedule asks, as the person said it: once at a moment, every day, every weekday, every
/// week on one day, or every few hours. Read in the time zone of the device that made it, so
/// "every morning at eight" is the person's eight wherever the machine is.
struct ScheduleRule: Codable, Sendable, Equatable {
    /// `once`, `daily`, `weekdays`, `weekly` or `hours`.
    var kind: String
    var at: Date?
    var hour: Int?
    var minute: Int?
    /// 1 is Sunday, as `Calendar` counts.
    var weekday: Int?
    /// For `hours`: how many hours apart, counted from `hour` each day.
    var every: Int?

    static let kinds: Set<String> = ["once", "daily", "weekdays", "weekly", "hours"]

    var isRepeating: Bool { kind != "once" }

    /// A rule this bridge can keep, or the reason it cannot.
    func problem() -> String? {
        guard Self.kinds.contains(kind) else { return "Unknown schedule \(kind)." }
        if kind == "once" { return at == nil ? "A one-off schedule needs its moment." : nil }
        guard let hour, (0...23).contains(hour), let minute, (0...59).contains(minute) else {
            return "A repeating schedule needs an hour and a minute."
        }
        if kind == "weekly", !(1...7).contains(weekday ?? 0) { return "A weekly schedule needs its day." }
        if kind == "hours", !(1...24).contains(every ?? 0) {
            return "Every few hours means every 1 to 24 hours."
        }
        return nil
    }

    /// The first time strictly after `moment` this rule asks.
    func next(after moment: Date, calendar: Calendar) -> Date? {
        switch kind {
        case "once":
            guard let at, at > moment else { return nil }
            return at
        case "hours":
            guard let every, every > 0, let minute else { return nil }
            let anchor = (hour ?? 0) % every
            let day = calendar.startOfDay(for: moment)
            guard var candidate = calendar.date(bySettingHour: anchor, minute: minute, second: 0, of: day)
            else { return nil }
            var steps = 0
            while candidate <= moment, steps < 200 {
                guard let stepped = calendar.date(byAdding: .hour, value: every, to: candidate) else {
                    return nil
                }
                candidate = stepped
                steps += 1
            }
            return candidate
        default:
            guard let hour, let minute else { return nil }
            var day = calendar.startOfDay(for: moment)
            for _ in 0..<15 {
                if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                    candidate > moment, accepts(day: day, calendar: calendar)
                {
                    return candidate
                }
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = tomorrow
            }
            return nil
        }
    }

    private func accepts(day: Date, calendar: Calendar) -> Bool {
        let weekdayOfDay = calendar.component(.weekday, from: day)
        switch kind {
        case "weekdays": return (2...6).contains(weekdayOfDay)
        case "weekly": return weekdayOfDay == weekday
        default: return true
        }
    }
}

struct ScheduleRun: Codable, Sendable, Equatable {
    var id: String
    var scheduledFor: Date
    var startedAt: Date?
    var endedAt: Date?
    var sessionID: String?
    /// `running`, `answered`, `quiet`, `failed`, `missed` or `caughtUp` (a run the machine
    /// owed while it was off, asked once when it came back; how it then ended is `ending`).
    var outcome: String
    /// For a caught-up run, how it ended: `answered`, `quiet` or `failed`.
    var ending: String?
    /// How many asking times passed with nothing asked: the machine was off, or the last run was
    /// still going.
    var missed: Int
    /// Why a run was missed (`off`, `busy`) or the words a failed one ended with.
    var failure: String?
}

struct Schedule: Codable, Sendable, Equatable {
    var id: String
    var text: String
    var title: String
    var model: String?
    var effort: String?
    var directory: String?
    var rule: ScheduleRule
    var timeZone: String
    var next: Date?
    var paused: Bool
    /// `continue` (every run in one conversation) or `fresh` (a new conversation each time).
    var thread: String
    var quiet: Bool
    var sessionID: String?
    var createdAt: Date
    var createdBy: String?
    var runs: [ScheduleRun]
}

struct ScheduleDraft: Codable, Sendable {
    var text: String
    var title: String?
    var model: String?
    var effort: String?
    var directory: String?
    var rule: ScheduleRule
    var timeZone: String?
    var thread: String?
    var quiet: Bool?
    var sessionID: String?
    var createdBy: String?
}

struct SchedulePatch: Codable, Sendable {
    var text: String?
    var title: String?
    var model: String?
    var effort: String?
    var rule: ScheduleRule?
    var timeZone: String?
    var paused: Bool?
    var thread: String?
    var quiet: Bool?
}

enum ScheduleError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case unknown

    var description: String {
        switch self {
        case .invalid(let why): return why
        case .unknown: return "There is no such schedule on this machine."
        }
    }
}

/// What the scheduler needs of the bridge it runs in: whether a conversation still exists, a new
/// one made for a schedule, and a scheduled prompt sent through the bridge's own road.
protocol ScheduleHost: Sendable {
    func scheduledConversationExists(_ id: String) async -> Bool
    func makeScheduledConversation(
        title: String, directory: String?, model: String?, effort: String?, scheduleID: String
    ) async -> String
    func sendScheduled(_ id: String, text: String, model: String?, effort: String?, quiet: Bool) async
        -> ScheduledSend
}

enum ScheduledSend: Sendable, Equatable {
    case started
    case queued(position: Int)
    case failed(String)
}

/// How a turn ended, as the scheduler reads it.
struct TurnEndNote: Sendable, Equatable {
    var answer: String
    var failure: String?
    var stopped: Bool
    var quiet: Bool
}

/// Where every session says its turn ended, for whoever is listening — the scheduler. One ear for
/// the whole bridge rather than one per session, because sessions are made in a dozen places.
final class TurnEnds: @unchecked Sendable {
    static let shared = TurnEnds()
    private let lock = NSLock()
    private var listener: (@Sendable (String, TurnEndNote) async -> Void)?

    func listen(_ listener: @escaping @Sendable (String, TurnEndNote) async -> Void) {
        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    func tell(_ sessionID: String, _ note: TurnEndNote) {
        lock.lock()
        let listener = self.listener
        lock.unlock()
        guard let listener else { return }
        Task { await listener(sessionID, note) }
    }
}

/// The words a quiet run is told to answer with when nothing changed, and the line the
/// conversation keeps in their place.
enum ScheduleWording {
    static let nothingNewWord = "NOTHING NEW"
    static let nothingNewLine = "Nothing new since the last check."
    static let quietNote = """


        (This message was sent by a schedule. If nothing worth telling has changed since your last \
        answer in this conversation, reply with exactly NOTHING NEW and nothing else.)
        """

    static func saysNothingNew(_ answer: String) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!*_`\"'"))
        return trimmed.count <= nothingNewWord.count + 12
            && trimmed.uppercased().hasPrefix(nothingNewWord)
    }
}

/// The schedules this machine keeps and asks, whether or not any client is open. A due schedule
/// is sent through the bridge's own road, so it queues behind a live turn rather than racing it,
/// into its own conversation or a new one; how the turn ended is read back from the session. A
/// machine that was off asks once for what it owed, never once per missed hour.
actor Scheduler {
    private let url: URL
    private let store: any ScheduleHost
    private var schedules: [Schedule]
    /// The run each conversation is waiting on, and how many turns ahead of it the conversation
    /// was already carrying when it was sent.
    private var waiting: [String: (schedule: String, run: String, ahead: Int)] = [:]
    private var onChange: (@Sendable () -> Void)?
    private let now: @Sendable () -> Date

    static let limit = 50
    static let runHistory = 30
    /// A machine that comes back within this long of a missed time asks once; any later, the
    /// moment has passed and it is only recorded.
    static let catchUpWindow: TimeInterval = 12 * 3_600
    static let tick: Duration = .seconds(20)
    /// A one-off that already ran is kept this long so its outcome can be read, then let go.
    static let finishedKeep: TimeInterval = 3 * 24 * 3_600

    init(url: URL, store: any ScheduleHost, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.store = store
        self.now = now
        schedules = Self.load(url)
    }

    func observe(_ change: @escaping @Sendable () -> Void) { onChange = change }

    func list() -> [Schedule] {
        schedules.sorted { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) }
    }

    func schedule(_ id: String) -> Schedule? { schedules.first { $0.id == id } }

    func create(_ draft: ScheduleDraft) throws -> Schedule {
        guard schedules.count < Self.limit else {
            throw ScheduleError.invalid("This machine keeps at most \(Self.limit) schedules.")
        }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8_000 else {
            throw ScheduleError.invalid("A schedule needs words to ask, at most 8000 characters.")
        }
        if let problem = draft.rule.problem() { throw ScheduleError.invalid(problem) }
        let zone = draft.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let moment = now()
        var schedule = Schedule(
            id: UUID().uuidString, text: text,
            title: Self.title(draft.title, text: text), model: draft.model, effort: draft.effort,
            directory: draft.directory, rule: draft.rule, timeZone: zone.identifier, next: nil,
            paused: false, thread: draft.thread == "fresh" ? "fresh" : "continue",
            quiet: draft.quiet ?? draft.rule.isRepeating, sessionID: draft.sessionID,
            createdAt: moment, createdBy: draft.createdBy, runs: [])
        schedule.next = schedule.rule.next(after: moment, calendar: Self.calendar(zone))
        guard schedule.next != nil else {
            throw ScheduleError.invalid("That time has already passed.")
        }
        schedules.append(schedule)
        save()
        return schedule
    }

    func update(_ id: String, _ patch: SchedulePatch) throws -> Schedule {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { throw ScheduleError.unknown }
        var schedule = schedules[index]
        if let text = patch.text?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !text.isEmpty, text.count <= 8_000 else {
                throw ScheduleError.invalid("A schedule needs words to ask, at most 8000 characters.")
            }
            schedule.text = text
        }
        if let title = patch.title { schedule.title = Self.title(title, text: schedule.text) }
        if let model = patch.model { schedule.model = model.isEmpty ? nil : model }
        if let effort = patch.effort { schedule.effort = effort.isEmpty ? nil : effort }
        if let thread = patch.thread { schedule.thread = thread == "fresh" ? "fresh" : "continue" }
        if let quiet = patch.quiet { schedule.quiet = quiet }
        if let zone = patch.timeZone.flatMap(TimeZone.init(identifier:)) { schedule.timeZone = zone.identifier }
        var reschedule = patch.timeZone != nil
        if let rule = patch.rule {
            if let problem = rule.problem() { throw ScheduleError.invalid(problem) }
            schedule.rule = rule
            reschedule = true
        }
        if let paused = patch.paused {
            if schedule.paused, !paused { reschedule = true }
            schedule.paused = paused
        }
        if reschedule {
            schedule.next = schedule.rule.next(after: now(), calendar: Self.calendar(schedule))
            if schedule.next == nil, patch.rule != nil {
                throw ScheduleError.invalid("That time has already passed.")
            }
        }
        schedules[index] = schedule
        save()
        return schedule
    }

    func delete(_ id: String) -> Bool {
        guard schedules.contains(where: { $0.id == id }) else { return false }
        schedules.removeAll { $0.id == id }
        waiting = waiting.filter { $0.value.schedule != id }
        save()
        return true
    }

    /// Asks now. A repeating schedule keeps its hour; a one-off is asked and done.
    func runNow(_ id: String) async throws -> Schedule {
        guard let schedule = schedules.first(where: { $0.id == id }) else { throw ScheduleError.unknown }
        await fire(schedule, scheduledFor: now(), missed: 0, caughtUp: false, advance: !schedule.rule.isRepeating)
        return schedules.first { $0.id == id } ?? schedule
    }

    func start() {
        Task { [weak self] in
            await self?.catchUp()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                await self?.tickOnce()
            }
        }
    }

    /// What a machine that was off owes: each schedule whose time passed while nothing was
    /// listening asks once if the latest of those times is recent, and records the rest.
    func catchUp() async {
        let moment = now()
        for schedule in schedules where !schedule.paused {
            guard let next = schedule.next, next <= moment else { continue }
            let calendar = Self.calendar(schedule)
            var missedTimes: [Date] = [next]
            var cursor = next
            while missedTimes.count < 1_000, let later = schedule.rule.next(after: cursor, calendar: calendar),
                later <= moment
            {
                missedTimes.append(later)
                cursor = later
            }
            let latest = missedTimes.last ?? next
            if moment.timeIntervalSince(latest) <= Self.catchUpWindow {
                await fire(
                    schedule, scheduledFor: latest, missed: missedTimes.count, caughtUp: true, advance: true)
            } else {
                record(
                    schedule.id,
                    ScheduleRun(
                        id: UUID().uuidString, scheduledFor: latest, startedAt: nil, endedAt: nil,
                        sessionID: nil, outcome: "missed", ending: nil, missed: missedTimes.count,
                        failure: "off"),
                    advanceFrom: moment)
            }
        }
        prune()
    }

    func tickOnce() async {
        let moment = now()
        for schedule in schedules where !schedule.paused {
            guard let next = schedule.next, next <= moment else { continue }
            if let last = schedule.runs.first, last.outcome == "running" {
                record(
                    schedule.id,
                    ScheduleRun(
                        id: UUID().uuidString, scheduledFor: next, startedAt: nil, endedAt: nil,
                        sessionID: nil, outcome: "missed", ending: nil, missed: 1, failure: "busy"),
                    advanceFrom: moment)
                continue
            }
            await fire(schedule, scheduledFor: next, missed: 0, caughtUp: false, advance: true)
        }
        prune()
    }

    /// A turn ended somewhere on this machine; if a schedule was waiting on it, its run is settled.
    func turnEnded(_ sessionID: String, _ note: TurnEndNote) {
        guard var entry = waiting[sessionID] else { return }
        guard entry.ahead <= 0 else {
            entry.ahead -= 1
            waiting[sessionID] = entry
            return
        }
        waiting[sessionID] = nil
        guard let index = schedules.firstIndex(where: { $0.id == entry.schedule }),
            let runIndex = schedules[index].runs.firstIndex(where: { $0.id == entry.run })
        else { return }
        var run = schedules[index].runs[runIndex]
        let ending: String
        if let failure = note.failure {
            ending = "failed"
            run.failure = String(failure.prefix(400))
        } else if note.stopped {
            ending = "failed"
            run.failure = "stopped"
        } else {
            ending = note.quiet ? "quiet" : "answered"
        }
        if run.outcome == "caughtUp" {
            run.ending = ending
        } else {
            run.outcome = ending
        }
        run.endedAt = now()
        schedules[index].runs[runIndex] = run
        save()
    }

    private func fire(
        _ schedule: Schedule, scheduledFor: Date, missed: Int, caughtUp: Bool, advance: Bool
    ) async {
        var sessionID: String?
        if schedule.thread == "continue", let existing = schedule.sessionID,
            await store.scheduledConversationExists(existing)
        {
            sessionID = existing
        }
        if sessionID == nil {
            sessionID = await store.makeScheduledConversation(
                title: schedule.title, directory: schedule.directory, model: schedule.model,
                effort: schedule.effort, scheduleID: schedule.id)
        }
        guard let sessionID else { return }
        let answeredBefore = schedule.runs.contains {
            $0.outcome == "answered" || $0.outcome == "quiet" || $0.ending == "answered" || $0.ending == "quiet"
        }
        let quiet = schedule.quiet && schedule.thread == "continue" && answeredBefore
        let outcome = await store.sendScheduled(
            sessionID, text: schedule.text, model: schedule.model, effort: schedule.effort, quiet: quiet)
        let moment = now()
        var run = ScheduleRun(
            id: UUID().uuidString, scheduledFor: scheduledFor, startedAt: moment, endedAt: nil,
            sessionID: sessionID, outcome: caughtUp ? "caughtUp" : "running", ending: nil,
            missed: caughtUp ? max(missed, 1) : missed, failure: caughtUp ? "off" : nil)
        switch outcome {
        case .started:
            waiting[sessionID] = (schedule.id, run.id, 0)
        case .queued(let position):
            waiting[sessionID] = (schedule.id, run.id, position)
        case .failed(let why):
            run.outcome = "failed"
            run.endedAt = moment
            run.failure = String(why.prefix(400))
        }
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }),
            schedule.thread == "continue"
        {
            schedules[index].sessionID = sessionID
        }
        record(schedule.id, run, advanceFrom: advance ? max(moment, scheduledFor) : nil)
    }

    private func record(_ id: String, _ run: ScheduleRun, advanceFrom moment: Date?) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].runs.insert(run, at: 0)
        if schedules[index].runs.count > Self.runHistory {
            schedules[index].runs.removeLast(schedules[index].runs.count - Self.runHistory)
        }
        if let moment {
            schedules[index].next = schedules[index].rule.next(
                after: moment, calendar: Self.calendar(schedules[index]))
        }
        save()
    }

    /// One-offs that ran and have been readable for a few days are let go.
    private func prune() {
        let moment = now()
        let before = schedules.count
        schedules.removeAll { schedule in
            guard !schedule.rule.isRepeating, schedule.next == nil,
                let last = schedule.runs.first, last.outcome != "running"
            else { return false }
            return moment.timeIntervalSince(last.endedAt ?? last.scheduledFor) > Self.finishedKeep
        }
        if schedules.count != before { save() }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(schedules) {
            try? data.write(to: url, options: .atomic)
        }
        onChange?()
    }

    private static func load(_ url: URL) -> [Schedule] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([Schedule].self, from: data)) ?? []
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func calendar(_ schedule: Schedule) -> Calendar {
        calendar(TimeZone(identifier: schedule.timeZone) ?? .current)
    }

    /// A short name for the schedule: the one given, or the first line of what it asks.
    static func title(_ given: String?, text: String) -> String {
        if let given = given?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
            return String(given.prefix(80))
        }
        let line = (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text)
            .trimmingCharacters(in: .whitespaces)
        guard line.count > 48 else { return line }
        let cut = line.prefix(48)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(word) + "…"
    }
}
