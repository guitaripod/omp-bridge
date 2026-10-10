import Foundation

/// One yes-or-no decision a person made about a conversation, and when they made it. The time is
/// the person's, not the arrival's: a phone that was offline delivers an old decision late, and
/// the later decision must win whichever reached the bridge first.
struct MarkDecision: Codable, Sendable, Equatable {
    var on: Bool
    var at: Date
}

/// Whether the person has looked at a conversation since it last moved.
enum ReadMark: String, Codable, Sendable {
    case seen
    case unread
}

/// What one `PATCH /sessions/:id` asks of a conversation's marks.
struct MarkChange: Sendable, Equatable {
    var saved: Bool?
    var pinned: Bool?
    var archived: Bool?
    var read: ReadMark?
    var at: Date?
}

/// Everything a person has decided about one conversation. Kept beside the session store rather
/// than inside a session record, so a transcript the bridge has only discovered can be marked
/// without being adopted. A decision that turned a mark off stays as a record of when, because
/// the next decision to arrive may be an older one that must lose.
struct SessionMarks: Codable, Sendable, Equatable {
    var saved: MarkDecision?
    var pinned: MarkDecision?
    var archived: MarkDecision?
    /// The reference time of the person's last look, in this bridge's clock, so it compares
    /// directly with the `updatedAt` this same bridge derives.
    var readAt: Date?
    var readDecided: Date?
    /// The last time this conversation appeared in a listing; what a prune measures its age by.
    var listedAt: Date?

    /// How far ahead of the bridge's clock a decision may claim to be. A client with a skewed
    /// clock would otherwise win every later decision for as long as the skew lasts.
    static let futureTolerance: TimeInterval = 300

    /// Applies one change, each mark on its own: a mark is left alone when the decision it
    /// already holds is later than this one, and an equal time applies.
    mutating func apply(_ change: MarkChange, updatedAt: Date?, now: Date) {
        let decided = Self.wholeSeconds(
            min(change.at ?? now, now.addingTimeInterval(Self.futureTolerance)))
        Self.decide(&saved, change.saved, at: decided)
        Self.decide(&pinned, change.pinned, at: decided)
        Self.decide(&archived, change.archived, at: decided)
        if let read = change.read, decided >= (readDecided ?? .distantPast) {
            readDecided = decided
            switch read {
            case .seen: markSeen(updatedAt: updatedAt, now: now)
            case .unread: readAt = Self.wholeSeconds((updatedAt ?? now).addingTimeInterval(-2))
            }
        }
    }

    /// A look is stamped with this bridge's clock, and does nothing to a chat already read past
    /// its last movement, so a client that reports every open does not make a summary change.
    private mutating func markSeen(updatedAt: Date?, now: Date) {
        if let readAt, let updatedAt, readAt >= updatedAt { return }
        readAt = Self.wholeSeconds(now)
    }

    private static func decide(_ slot: inout MarkDecision?, _ on: Bool?, at: Date) {
        guard let on, at >= (slot?.at ?? .distantPast) else { return }
        slot = MarkDecision(on: on, at: at)
    }

    /// Dates travel as whole seconds, so a time kept finer than that would not survive a restart
    /// and a decision would compare differently before and after one.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

/// Every conversation's marks on this machine. Pure state: the store owns one, persists it, and
/// asks it to stamp listings, so the decision logic is testable without an actor or a disk.
struct MarksLedger: Sendable, Equatable {
    private(set) var entries: [String: SessionMarks] = [:]

    /// How long a conversation may be absent from every listing before its marks are forgotten.
    static let pruneAfter: TimeInterval = 30 * 24 * 3600

    /// How stale a recorded sighting may get before it is refreshed, so a listing every second
    /// does not turn into a write every second.
    static let listedGrain: TimeInterval = 24 * 3600

    /// Whether the entry changed, which is whether there is anything to persist.
    @discardableResult
    mutating func apply(
        _ change: MarkChange, to id: String, updatedAt: Date?, now: Date = Date()
    ) -> Bool {
        let before = entries[id]
        var marks = before ?? SessionMarks()
        marks.apply(change, updatedAt: updatedAt, now: now)
        guard marks != (before ?? SessionMarks()) else { return false }
        if before == nil { marks.listedAt = SessionMarks.wholeSeconds(now) }
        entries[id] = marks
        return true
    }

    @discardableResult
    mutating func remove(_ id: String) -> Bool { entries.removeValue(forKey: id) != nil }

    /// The summary with all five marks stamped on. `pinned` and `archived` are always present,
    /// because their presence is how a client tells *not pinned* from *this bridge cannot say*.
    func stamping(_ summary: SessionSummary) -> SessionSummary {
        let marks = entries[summary.id]
        var stamped = summary
        stamped.saved = marks?.saved?.on ?? false
        stamped.pinned = marks?.pinned?.on ?? false
        stamped.pinnedAt = stamped.pinned == true ? marks?.pinned?.at : nil
        stamped.archived = marks?.archived?.on ?? false
        stamped.readAt = marks?.readAt
        return stamped
    }

    /// Records that these conversations were listed just now. Returns whether any sighting moved
    /// far enough to be worth writing down.
    @discardableResult
    mutating func noteListed(_ ids: some Sequence<String>, now: Date = Date()) -> Bool {
        var moved = false
        for id in ids {
            guard var marks = entries[id] else { continue }
            if let seen = marks.listedAt, now.timeIntervalSince(seen) < Self.listedGrain { continue }
            marks.listedAt = SessionMarks.wholeSeconds(now)
            entries[id] = marks
            moved = true
        }
        return moved
    }

    /// Forgets the marks of conversations no listing has held for thirty days, never one that is
    /// listed now. Returns whether anything was dropped.
    mutating func prune(listed: Set<String>, now: Date = Date()) -> Bool {
        let stale = entries.filter { id, marks in
            !listed.contains(id)
                && now.timeIntervalSince(marks.listedAt ?? now) > Self.pruneAfter
        }
        for id in stale.keys { entries[id] = nil }
        return !stale.isEmpty
    }

    /// Reads `marks.json`; a missing or unreadable file is a ledger nobody has written to yet.
    /// An entry that predates sightings is dated as seen now, so a prune never ages it from nothing.
    static func load(from url: URL, now: Date = Date()) -> MarksLedger {
        var ledger = MarksLedger()
        if let data = try? Data(contentsOf: url),
            let stored = try? WireCoding.decoder.decode([String: SessionMarks].self, from: data)
        {
            ledger.entries = stored
        }
        for id in ledger.entries.keys where ledger.entries[id]?.listedAt == nil {
            ledger.entries[id]?.listedAt = SessionMarks.wholeSeconds(now)
        }
        return ledger
    }

    func write(to url: URL) {
        guard let data = try? WireCoding.encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
