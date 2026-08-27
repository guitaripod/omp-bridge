import Foundation

struct SessionRecord: Codable, Sendable {
    var id: String
    var title: String
    var directory: String?
    var model: String
    var effort: String
    var createdAt: Date
    var updatedAt: Date
    var ompSessionID: String?
    var ompSessionFile: String?
    var customTitle: Bool?
    var autoTitled: Bool?
    var turns: [TurnRecord]
    var totalCostUSD: Double
    var totalTokens: TokenCounts
    var lastCostUSD: Double?
    var lastTokens: Int?
    var interruption: Interruption?
    var autoResume: Bool?
    var ownedTranscriptIDs: [String]?
}

actor SessionStore {
    private let path: String
    private var records: [String: SessionRecord] = [:]
    private var hidden: [String] = []
    private var persistTask: Task<Void, Never>?

    init(path: String) {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        if let data = FileManager.default.contents(atPath: path),
            let decoded = try? WireCoding.decoder.decode([SessionRecord].self, from: data)
        {
            var loaded: [String: SessionRecord] = [:]
            for record in decoded { loaded[record.id] = record }
            self.records = loaded
        }
        if let data = FileManager.default.contents(atPath: dir + "/hidden.json"),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            self.hidden = decoded
        }
    }

    func record(for id: String) -> SessionRecord? { records[id] }

    func upsert(_ record: SessionRecord) {
        records[record.id] = record
        schedulePersist()
    }

    func remove(_ id: String) -> SessionRecord? {
        let record = records.removeValue(forKey: id)
        if let owned = record?.ownedTranscriptIDs, !owned.isEmpty {
            hidden.append(contentsOf: owned)
        } else if let ompID = record?.ompSessionID {
            hidden.append(ompID)
        }
        persistNow()
        return record
    }

    func isHidden(_ ompSessionID: String) -> Bool { hidden.contains(ompSessionID) }

    func hiddenList() -> [String] { hidden }

    func allRecords() -> [SessionRecord] {
        records.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [path] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self.persistNow()
        }
    }

    func flush() {
        persistNow()
    }

    private func persistNow() {
        guard let data = try? WireCoding.encoder.encode(records.values.sorted(by: { $0.createdAt < $1.createdAt }))
        else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        let dir = (path as NSString).deletingLastPathComponent
        if let hiddenData = try? JSONEncoder().encode(hidden) {
            try? hiddenData.write(to: URL(fileURLWithPath: dir + "/hidden.json"), options: .atomic)
        }
    }
}
