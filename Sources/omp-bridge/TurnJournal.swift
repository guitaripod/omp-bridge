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

    func clear(_ sessionID: String, turnID: String? = nil) {
        var all = readAll()
        if let turnID, all[sessionID]?.turnID != turnID { return }
        all.removeValue(forKey: sessionID)
        save(all)
    }

    func interruptedEntries() -> [JournalEntry] {
        readAll().values.filter { entry in
            guard let pid = entry.pid else { return true }
            return !Self.isAlive(pid)
        }
    }

    /// Read with the date format ``save(_:)`` writes. Read with the default one, every entry failed
    /// to decode: a turn killed by a crash or a restart was never recovered as an interruption,
    /// and each write or clear rewrote the file with only its own entry, dropping every other
    /// conversation's turn in flight.
    private func readAll() -> [String: JournalEntry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: JournalEntry].self, from: data)) ?? [:]
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
