import Foundation

/// What an answer began with, cut down to a line a list row can quote.
///
/// A finished turn nobody has read is news, and the news is what the agent said, not the fact
/// that it stopped. The words are the answer's own opening: an answer leads with its result, and
/// a row has room for a sentence or two. Markup is taken off because a row draws plain text, and
/// code, tables and rules are skipped because none of them reads as a sentence.
enum LastWords {
    static let limit = 200

    /// How long after its last change a chat can still carry a quote. A row older than this is
    /// found by its title, and a listing of two thousand chats must not grow by a sentence each.
    static let window: TimeInterval = 14 * 24 * 3600

    /// Whether a row could still be unread on some device: it moved inside the window, and no
    /// device has read it since it last moved. The second of slack is the one a client allows
    /// when it compares the same two times.
    static func mayBeUnread(updatedAt: Date, readAt: Date?, now: Date) -> Bool {
        guard now.timeIntervalSince(updatedAt) <= window else { return false }
        guard let readAt else { return true }
        return updatedAt.timeIntervalSince(readAt) > 1
    }

    /// What the answer that closed a conversation's last turn began with: the newest text the
    /// model wrote after the last thing a person sent. A turn that ended without a word has
    /// nothing to quote, and the answer before it is not this turn's.
    static func quote(in messages: [Message]) -> String? {
        for message in messages.reversed() {
            switch message.role {
            case .user:
                return nil
            case .assistant:
                for part in message.parts.reversed() {
                    guard case .text(let value) = part, let said = digest(value) else { continue }
                    return said
                }
            case .system:
                continue
            }
        }
        return nil
    }

    /// The opening of `text` as one plain line, or nil when it says nothing a row could quote.
    static func digest(_ text: String) -> String? {
        var words: [Substring] = []
        var length = 0
        var fenced = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenced.toggle()
                continue
            }
            guard !fenced, let line = plain(trimmed) else { continue }
            for word in line.split(separator: " ", omittingEmptySubsequences: true) {
                words.append(word)
                length += word.count + 1
            }
            if length > limit { break }
        }
        guard !words.isEmpty else { return nil }
        return clipped(words.joined(separator: " "))
    }

    /// One line with its markup taken off, or nil for a line that is only markup.
    private static func plain(_ line: String) -> String? {
        if line.hasPrefix("|") || isRule(line) { return nil }
        var rest = Substring(line)
        while let first = rest.first, first == "#" || first == ">" || first == " " {
            rest = rest.dropFirst()
        }
        for bullet in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            rest = rest.dropFirst(bullet.count)
            break
        }
        var out = String(rest)
        for mark in ["**", "__", "`"] { out = out.replacingOccurrences(of: mark, with: "") }
        out = unlinked(out)
        let said = out.trimmingCharacters(in: .whitespaces)
        return said.isEmpty ? nil : said
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" || $0 == "=" || $0 == " " }
    }

    /// `[words](address)` as its words. A bracket that opens no link is kept as written and the
    /// line is read on past it, so `array[0]` early in a sentence does not leave a link after it
    /// in its markup.
    private static func unlinked(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            guard let close = rest[open...].firstIndex(of: "]"),
                rest.index(after: close) < rest.endIndex, rest[rest.index(after: close)] == "(",
                let end = rest[close...].firstIndex(of: ")")
            else {
                out += rest[...open]
                rest = rest[rest.index(after: open)...]
                continue
            }
            out += rest[..<open]
            out += rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    /// Cut at a word, never inside one, and marked as cut.
    private static func clipped(_ text: String) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit - 1)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }
}
