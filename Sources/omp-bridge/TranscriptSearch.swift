import Foundation

enum TranscriptSearch {
    static let defaultLimit = 40
    static let matchesPerSession = 4
    static let snippetRadius = 100
    static let budget: TimeInterval = 3.0
    private static let heartbeat = 512

    struct Term: Sendable {
        let bytes: [UInt8]
        let skip: [Int]

        init(_ raw: String) {
            let bytes = raw.utf8.map(TranscriptSearch.fold)
            var skip = [Int](repeating: bytes.count, count: 256)
            if bytes.count > 1 {
                for index in 0..<(bytes.count - 1) {
                    skip[Int(bytes[index])] = bytes.count - 1 - index
                }
            }
            self.bytes = bytes
            self.skip = skip
        }
    }

    struct Query: Sendable {
        let terms: [Term]
        let rarest: Term

        init?(_ raw: String) {
            let words =
                raw.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard let longest = words.max(by: { $0.utf8.count < $1.utf8.count }) else { return nil }
            self.terms = words.map(Term.init)
            self.rarest = Term(longest)
        }

        func matches(_ haystack: String) -> Bool {
            var copy = haystack
            return copy.withUTF8 { buffer in
                terms.allSatisfy { TranscriptSearch.firstOffset(of: $0, in: buffer) != nil }
            }
        }

        func earliest(in haystack: String) -> (offset: Int, length: Int)? {
            var copy = haystack
            return copy.withUTF8 { buffer -> (offset: Int, length: Int)? in
                var best: (offset: Int, length: Int)?
                for term in terms {
                    guard let at = TranscriptSearch.firstOffset(of: term, in: buffer) else { continue }
                    if best == nil || at < best!.offset { best = (at, term.bytes.count) }
                }
                return best
            }
        }
    }

    static func search(root: String, query raw: String, limit: Int) async -> SearchResponse {
        guard let query = Query(raw) else {
            return SearchResponse(query: raw, hits: [], scanned: 0, truncated: false)
        }
        let files = transcripts(under: URL(fileURLWithPath: root))
        let deadline = Date().addingTimeInterval(budget)
        let lanes = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        var merged: [String: SearchHit] = [:]
        var scanned = 0
        var truncated = false
        var next = 0

        await withTaskGroup(of: (Bool, SearchHit?).self) { group in
            func enqueue() -> Bool {
                guard next < files.count else { return false }
                let file = files[next]
                next += 1
                group.addTask(priority: .userInitiated) {
                    guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe)
                    else { return (false, nil) }
                    guard offset(of: query.rarest, in: data) != nil else { return (true, nil) }
                    return (true, search(file: file, data: data, query: query, deadline: deadline))
                }
                return true
            }
            for _ in 0..<lanes where enqueue() {}
            var considered = 0
            while let (read, hit) = await group.next() {
                considered += 1
                if read { scanned += 1 }
                if let hit { merged[hit.sessionID] = hit }
                if merged.count >= limit || Date() >= deadline {
                    truncated = considered < files.count
                    group.cancelAll()
                    break
                }
                _ = enqueue()
            }
        }

        var hits = Array(merged.values)
        for index in hits.indices where hits[index].title.isEmpty {
            hits[index].title = "Session"
        }
        hits.sort { $0.updatedAt > $1.updatedAt }
        return SearchResponse(
            query: raw, hits: Array(hits.prefix(limit)), scanned: scanned, truncated: truncated)
    }

    private struct Transcript {
        let url: URL
        let id: String
        let modifiedAt: Date
    }

    private static func transcripts(under root: URL) -> [Transcript] {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        else { return [] }
        var found: [Transcript] = []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard
                let files = try? manager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles)
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                found.append(
                    Transcript(
                        url: file, id: file.deletingPathExtension().lastPathComponent,
                        modifiedAt: modified(file)))
            }
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    private static func search(
        file: Transcript, data: Data, query: Query, deadline: Date
    ) -> SearchHit? {
        var matches: [SearchHitMatch] = []
        var total = 0
        var title: String?
        var directory: String?
        var lines = 0

        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            lines += 1
            if lines % heartbeat == 0, Task.isCancelled || Date() >= deadline { break }
            let identified = directory != nil && title != nil
            guard !identified || offset(of: query.rarest, in: line) != nil else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            switch object["type"] as? String {
            case "title":
                if title == nil { title = object["title"] as? String }
            case "session":
                if directory == nil { directory = object["cwd"] as? String }
            case "message":
                let stamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
                for passage in passages(in: object) {
                    if title == nil, passage.role == "user", passage.kind == "text" {
                        title = String(passage.text.prefix(80))
                    }
                    guard query.matches(passage.text) else { continue }
                    total += 1
                    guard matches.count < matchesPerSession else { continue }
                    matches.append(
                        SearchHitMatch(
                            role: passage.role, kind: passage.kind,
                            text: snippet(passage.text, around: query), at: stamp))
                }
            default:
                continue
            }
        }
        guard !matches.isEmpty || total > 0 else { return nil }
        return SearchHit(
            sessionID: file.id, title: title ?? "", directory: directory,
            updatedAt: file.modifiedAt, matches: matches, total: total)
    }

    private struct Passage {
        let role: String
        let kind: String
        let text: String
    }

    private static func passages(in line: [String: Any]) -> [Passage] {
        guard let message = line["message"] as? [String: Any] else { return [] }
        let rawRole = message["role"] as? String ?? "assistant"
        let role = rawRole == "user" ? "user" : "assistant"
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var found: [Passage] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    found.append(Passage(role: role, kind: "text", text: text))
                }
            case "thinking":
                if let text = block["thinking"] as? String, !text.isEmpty {
                    found.append(Passage(role: role, kind: "reasoning", text: text))
                }
            default:
                continue
            }
        }
        return found
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    private static func snippet(_ text: String, around query: Query) -> String {
        guard let match = query.earliest(in: text) else {
            return flattened(String(text.prefix(snippetRadius * 2)))
        }
        let anchor = boundary(at: match.offset, in: text)
        let tail = boundary(at: match.offset + match.length, in: text)
        let start =
            text.index(anchor, offsetBy: -snippetRadius, limitedBy: text.startIndex)
            ?? text.startIndex
        let end =
            text.index(tail, offsetBy: snippetRadius, limitedBy: text.endIndex) ?? text.endIndex
        var out = flattened(String(text[start..<end]))
        if start > text.startIndex { out = "…" + out }
        if end < text.endIndex { out += "…" }
        return out
    }

    private static func boundary(at offset: Int, in text: String) -> String.Index {
        let utf8 = text.utf8
        guard let byte = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex)
        else { return text.endIndex }
        return String.Index(byte, within: text) ?? text.startIndex
    }

    private static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func firstOffset(of term: Term, in buffer: UnsafeBufferPointer<UInt8>) -> Int? {
        let length = term.bytes.count
        guard length > 0, buffer.count >= length, let base = buffer.baseAddress else { return nil }
        var offset = 0
        while offset <= buffer.count - length {
            var index = length - 1
            while index >= 0, fold(base[offset + index]) == term.bytes[index] { index -= 1 }
            if index < 0 { return offset }
            offset += term.skip[Int(fold(base[offset + length - 1]))]
        }
        return nil
    }

    private static func offset(of term: Term, in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return firstOffset(of: term, in: UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    @inline(__always)
    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
}
