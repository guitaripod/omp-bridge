import Foundation

struct JournalEntry: Codable, Sendable {
    var turnID: String
    var sessionID: String
    var ompSessionFile: String?
    var prompt: String
    var startedAt: Date
    var pid: Int?
}

actor TurnJournal {
    private let path: String

    init(path: String) {
        self.path = path
    }

    func write(_ entry: JournalEntry) {
        var all = readAll()
        all[entry.sessionID] = entry
        save(all)
    }

    func clear(_ sessionID: String) {
        var all = readAll()
        all.removeValue(forKey: sessionID)
        save(all)
    }

    func interruptedEntries() -> [JournalEntry] {
        readAll().values.filter { entry in
            guard let pid = entry.pid else { return true }
            return !Self.isAlive(pid)
        }
    }

    private func readAll() -> [String: JournalEntry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONDecoder().decode([String: JournalEntry].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: JournalEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(all) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    static func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0
    }
}
