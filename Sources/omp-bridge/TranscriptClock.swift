import Foundation

/// When a conversation last moved and whether a turn is still open in it, read from the rows that
/// are the conversation rather than from the file's date. oh-my-pi keeps its own books in the same
/// file: every engine that stops signs it with a `session_exit` row, so restarting this service
/// signed every chat it had an engine open for, and a model, level, title or credential change is
/// a row too. A list sorted by the file's date moved each of those chats to the top the moment the
/// service came back, and wore them as live for minutes after.
struct TranscriptActivity: Equatable, Sendable {
    /// The newest row that belongs to the conversation.
    var lastSaid: Date?
    /// Whether the conversation's newest row leaves the engine something to answer — a prompt, a
    /// tool call or its result, a notice handed to the model mid-run. An answer that ended, whether
    /// it stopped, was cut off, failed or was aborted, closes the turn.
    var turnOpen = false
    /// Whether the engine writing the transcript has said since then that it stopped.
    var engineExited = false

    /// A turn somebody is running from somewhere else: still open, its engine still there, and
    /// heard from after `horizon`.
    func isLive(after horizon: Date) -> Bool {
        turnOpen && !engineExited && (lastSaid ?? .distantPast) > horizon
    }
}

enum TranscriptClock {
    /// The last few rows answer almost every transcript, and a tail that is one enormous tool
    /// result needs a wider look before the whole file is read.
    private static let tailWindows = [64 * 1024, 4 * 1024 * 1024, Int.max]

    static func read(atPath path: String) -> TranscriptActivity {
        guard let handle = FileHandle(forReadingAtPath: path) else { return TranscriptActivity() }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        for window in tailWindows {
            let span = min(size, window)
            guard (try? handle.seek(toOffset: UInt64(size - span))) != nil,
                let data = try? handle.read(upToCount: span)
            else { break }
            if let activity = read(tail: data, isWholeFile: span == size) { return activity }
            if span == size { break }
        }
        return TranscriptActivity()
    }

    /// Reads rows backwards from the end of `data` until the conversation's newest row and the
    /// turn it leaves are both known. A window that does not begin at the top of the file may
    /// begin inside a row, so nil hands that row to a wider window rather than guessing.
    static func read(tail data: Data, isWholeFile: Bool) -> TranscriptActivity? {
        var activity = TranscriptActivity()
        var end = data.endIndex
        while end > data.startIndex {
            let newline = data[data.startIndex..<end].lastIndex(of: 0x0A)
            if newline == nil, !isWholeFile { return nil }
            let start = newline.map { data.index(after: $0) } ?? data.startIndex
            let line = data[start..<end]
            end = newline ?? data.startIndex
            guard !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: Data(line))
            else { continue }
            let row = JSONValue.from(object)
            if activity.lastSaid == nil {
                if isExit(row) {
                    activity.engineExited = true
                    continue
                }
                guard let said = stamp(of: row) else { continue }
                activity.lastSaid = said
            } else if stamp(of: row) == nil {
                continue
            }
            if let open = leavesTurnOpen(row) {
                activity.turnOpen = open
                return activity
            }
        }
        return isWholeFile ? activity : nil
    }

    /// When a row was written, if it is part of the conversation. The engine's own bookkeeping —
    /// a title, a model, level or tier switch, a pinned credential, the engine stopping — says
    /// nothing about when anyone last spoke, and neither does a row type this reader has never
    /// met.
    static func stamp(of row: JSONValue) -> Date? {
        guard isConversation(row) else { return nil }
        if let written = row["timestamp"]?.stringValue, let date = TranscriptLoader.isoDate(written) {
            return date
        }
        return row["message"]?["timestamp"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    private static func isConversation(_ row: JSONValue) -> Bool {
        switch row["type"]?.stringValue {
        case "message", "custom_message", "compaction", "branch_summary":
            return true
        case "custom":
            return row["customType"]?.stringValue == "tool_execution_start"
        default:
            return false
        }
    }

    private static func isExit(_ row: JSONValue) -> Bool {
        row["type"]?.stringValue == "custom" && row["customType"]?.stringValue == "session_exit"
    }

    /// Whether a conversation row leaves the engine something to answer. Nil for a compaction,
    /// which lands between turns and in the middle of one alike, so the row before it decides. The
    /// notice oh-my-pi files after an abort, carrying the thinking that was cut off to the next
    /// turn, closes like the abort it follows, and moving along the conversation's tree is not the
    /// engine working.
    private static func leavesTurnOpen(_ row: JSONValue) -> Bool? {
        switch row["type"]?.stringValue {
        case "message":
            guard row["message"]?["role"]?.stringValue == "assistant" else { return true }
            return row["message"]?["stopReason"]?.stringValue == "toolUse"
        case "custom_message":
            return row["customType"]?.stringValue != "interrupted-thinking"
        case "custom":
            return true
        case "compaction":
            return nil
        default:
            return false
        }
    }
}
