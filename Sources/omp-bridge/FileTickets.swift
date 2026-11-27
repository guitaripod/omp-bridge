import Foundation

/// A player's way in to one file on this machine.
///
/// AVPlayer and mpv open a URL and ask for byte ranges as they play; neither knows the password a
/// client sends. A client asks `POST /files/ticket` for a file (with its password, like any
/// request), and the ticket it gets back admits `GET /files/raw?ticket=` for that one file without
/// one. A ticket lives while it is used: each read pushes its end out, so a long film being watched
/// never expires under the person, and one nobody reads for `lifetime` is gone. They live in
/// memory only, so a restart revokes them all and a client asks again.
actor FileTickets {
    private struct Entry {
        let path: String
        var expires: Date
    }

    private var byTicket: [String: Entry] = [:]
    private var byPath: [String: String] = [:]
    private let lifetime: TimeInterval
    private let capacity: Int
    private let clock: @Sendable () -> Date

    init(
        lifetime: TimeInterval = 6 * 3600, capacity: Int = 512,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lifetime = lifetime
        self.capacity = capacity
        self.clock = clock
    }

    /// A ticket for the file at `path`: the one already out for it while that one lives, so a
    /// transcript that names one clip ten times holds one ticket.
    func issue(path: String) -> String {
        let now = clock()
        if let held = byPath[path], var entry = byTicket[held], entry.expires > now {
            entry.expires = now.addingTimeInterval(lifetime)
            byTicket[held] = entry
            return held
        }
        prune(now: now)
        if byTicket.count >= capacity, let oldest = byTicket.min(by: { $0.value.expires < $1.value.expires }) {
            forget(oldest.key)
        }
        let ticket = Self.mint()
        byTicket[ticket] = Entry(path: path, expires: now.addingTimeInterval(lifetime))
        byPath[path] = ticket
        return ticket
    }

    /// The file a ticket admits, with its life extended by this read, or nil for a ticket this
    /// process never issued or that has run out.
    func path(for ticket: String) -> String? {
        let now = clock()
        guard var entry = byTicket[ticket] else { return nil }
        guard entry.expires > now else {
            forget(ticket)
            return nil
        }
        entry.expires = now.addingTimeInterval(lifetime)
        byTicket[ticket] = entry
        return entry.path
    }

    var count: Int { byTicket.count }

    private func prune(now: Date) {
        for (ticket, entry) in byTicket where entry.expires <= now { forget(ticket) }
    }

    private func forget(_ ticket: String) {
        guard let entry = byTicket.removeValue(forKey: ticket) else { return }
        if byPath[entry.path] == ticket { byPath[entry.path] = nil }
    }

    /// Thirty-two bytes from the system's secure generator, as hex: a URL that names a file has to
    /// be unguessable, because it is the only key that file's reads need.
    private static func mint() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%016llx", generator.next()) }.joined()
    }
}

/// One `Range: bytes=` a player sent, read against the size of the file it asked about.
///
/// A single range is all a media player asks for; a list of ranges is answered with the whole
/// file, which the HTTP spec allows a server to do with any Range it chooses not to honor.
enum ByteRange: Equatable {
    case whole
    case part(lower: Int, upper: Int)
    case unsatisfiable

    static func parse(_ header: String?, size: Int) -> ByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.hasPrefix("bytes=")
        else { return .whole }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let suffix = Int(last), suffix > 0 else { return .unsatisfiable }
            guard size > 0 else { return .unsatisfiable }
            return .part(lower: max(0, size - suffix), upper: size - 1)
        }
        guard let lower = Int(first), lower >= 0 else { return .whole }
        guard lower < size else { return .unsatisfiable }
        if last.isEmpty { return .part(lower: lower, upper: size - 1) }
        guard let upper = Int(last), upper >= lower else { return .whole }
        return .part(lower: lower, upper: min(upper, size - 1))
    }
}
