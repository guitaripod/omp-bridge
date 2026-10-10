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
    /// Set only by the model titler. The key is deliberately not the older `autoTitled`, which
    /// also stood for a title cut out of the first prompt: a record written before there was a
    /// namer decodes this as nil and so is named properly the first time it is restored.
    var titledByModel: Bool?
    var turns: [TurnRecord]
    var totalCostUSD: Double
    var totalTokens: TokenCounts
    var lastCostUSD: Double?
    var lastTokens: Int?
    var interruption: Interruption?
    var autoResume: Bool?
    var ownedTranscriptIDs: [String]?
    /// When a fork was made. Its transcript is a copy whose every row is older than the fork, and a
    /// chat is dated by what was said in it, so this is the one thing that keeps a fork nobody has
    /// spoken in yet where it was born.
    var forkedAt: Date?
}

actor SessionStore {
    private let path: String
    private var records: [String: SessionRecord] = [:]
    private var hidden: [String] = []
    private var marks: MarksLedger
    private var marksDirty = false
    private var persistTask: Task<Void, Never>?

    init(path: String) {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        self.marks = MarksLedger.load(from: Self.marksURL(besides: path))
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

    /// Drops a record without hiding its transcripts — for retiring a duplicate whose transcript
    /// another record keeps answering for. `remove(_:)`'s hide would blind the survivor too.
    func removeWithoutHiding(_ id: String) -> SessionRecord? {
        let record = records.removeValue(forKey: id)
        if record != nil { persistNow() }
        return record
    }

    /// Records what a person decided about a conversation. Kept beside the records rather than
    /// inside one so a transcript the bridge has only discovered can be marked without being
    /// adopted into a store that would then own its title.
    @discardableResult
    func applyMarks(_ id: String, _ change: MarkChange, updatedAt: Date?, now: Date = Date())
        -> Bool
    {
        guard marks.apply(change, to: id, updatedAt: updatedAt, now: now) else { return false }
        persistMarks()
        return true
    }

    /// The same rows, each carrying what the person decided about it. Applied to the whole
    /// listing rather than to the sessions alone, because part of a listing is transcripts the
    /// store has never adopted.
    func stampingMarks(_ summaries: [SessionSummary], now: Date = Date()) -> [SessionSummary] {
        if marks.noteListed(summaries.map(\.id), now: now) { marksDirty = true }
        return summaries.map { marks.stamping($0) }
    }

    /// Forgets the marks of conversations nothing has listed for a month, and writes down the
    /// sightings that kept the others alive.
    func pruneMarks(listed: Set<String>, now: Date = Date()) {
        let dropped = marks.prune(listed: listed, now: now)
        if dropped || marksDirty { persistMarks() }
    }

    /// A deleted conversation takes its marks with it.
    func forgetMarks(_ id: String) {
        guard marks.remove(id) else { return }
        persistMarks()
    }

    private static func marksURL(besides path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
            .appendingPathComponent("marks.json")
    }

    private func persistMarks() {
        marksDirty = false
        marks.write(to: Self.marksURL(besides: path))
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
