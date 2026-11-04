import Crypto
import Foundation

/// An answer a client may already hold, and how to tell it so.
///
/// A client re-reads a transcript every time it opens one and every time its stream reconnects,
/// which on a phone is every time it wakes, and most of those reads find the conversation exactly
/// as it was: megabytes sent again for nothing, through a relay when the phone is away from home.
/// So the answer carries a tag, the digest of its own bytes, and a read that already holds that
/// tag is answered 304 with no body. A digest moves exactly when a byte of the answer moves, so a
/// tag can never vouch for a copy that has gone stale, whatever changed: a message, a turn opening,
/// background work.
enum Validation {
    enum Reply: Equatable {
        case full(Data, tag: String)
        case unchanged(tag: String)
    }

    static func reply(body: Data, ifNoneMatch: String?) -> Reply {
        let tag = self.tag(of: body)
        if let ifNoneMatch, matches(ifNoneMatch, tag) { return .unchanged(tag: tag) }
        return .full(body, tag: tag)
    }

    /// Ninety-six bits of the digest, quoted as a strong validator.
    static func tag(of body: Data) -> String {
        let digest = SHA256.hash(data: body)
        let hex = digest.prefix(12).map { byte in
            let text = String(byte, radix: 16)
            return byte < 16 ? "0" + text : text
        }
        return "\"" + hex.joined() + "\""
    }

    /// `If-None-Match` may list several tags, mark one weak, or say `*` for any copy at all.
    static func matches(_ header: String, _ tag: String) -> Bool {
        header.split(separator: ",").contains { candidate in
            var trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if trimmed == "*" { return true }
            if trimmed.hasPrefix("W/") { trimmed.removeFirst(2) }
            return trimmed == tag
        }
    }
}
