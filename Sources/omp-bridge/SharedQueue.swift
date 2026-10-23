import Foundation

/// One message waiting behind a running turn, as every client of the conversation sees it. The
/// bytes of its attachments are not here: they arrive once with the enqueue and live on disk.
struct QueuedItem: Codable, Sendable, Equatable {
    static let promptKind = "prompt"
    static let commandKind = "command"

    var id: String
    var text: String
    var kind: String
    var model: String?
    var effort: String?
    var attachments: [QueueAttachment]
    var createdAt: Date
}

/// What a queued item's attachment is, without its bytes.
struct QueueAttachment: Codable, Sendable, Equatable {
    var mime: String
    var filename: String
    var size: Int
}

/// A queued item and the files the bridge kept for it, which are what the user message shows and
/// what the engine is pointed at when the item starts.
struct HeldQueueItem: Codable, Sendable {
    var item: QueuedItem
    var files: [FileRef]
}

/// Everything a client needs to draw the shared queue: the items in arrival order, and whether
/// draining is held back after a Stop or a restart.
struct QueueSnapshot: Codable, Sendable, Equatable {
    var queue: [QueuedItem]
    var paused: Bool
}

/// One session's queue as it is written to the state directory.
struct PersistedQueue: Codable, Sendable {
    var items: [HeldQueueItem]
    var paused: Bool
}

/// An attachment the route wrote to disk, and how many bytes it holds.
struct StoredAttachment: Sendable {
    let file: FileRef
    let size: Int
}

struct EnqueueRequest: Codable, Sendable {
    var id: String
    var text: String
    var kind: String?
    var model: String?
    var effort: String?
    var attachments: [SendAttachment]?
}

struct EditQueuedRequest: Codable, Sendable {
    var text: String?
    var model: String?
    var effort: String?
}

/// The answer to an enqueue: whether the item went straight into a turn, and the queue after it.
struct EnqueueAccepted: Encodable, Sendable {
    let started: Bool
    let queue: [QueuedItem]
    let paused: Bool
}

/// What the session did with an enqueue.
enum EnqueueOutcome: Sendable, Equatable {
    case accepted(started: Bool, snapshot: QueueSnapshot)
    case invalid(String)
}

/// What the session did with an edit or a cancel.
enum QueueChangeOutcome: Sendable, Equatable {
    case changed(QueueSnapshot)
    case alreadyStarted
}

enum QueueRefusal {
    static let alreadyStarted = "already_started"
}

/// Where a session's queue lives between runs: one small file per session in the state
/// directory, so a queue outlives the bridge without joining the session records.
enum QueueFile {
    static func url(stateDir: String, sessionID: String) -> URL {
        let safe = String(sessionID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return URL(fileURLWithPath: stateDir)
            .appendingPathComponent("queues", isDirectory: true)
            .appendingPathComponent("\(safe).json")
    }

    static func load(from url: URL) -> PersistedQueue? {
        guard let data = try? Data(contentsOf: url),
            let queue = try? WireCoding.decoder.decode(PersistedQueue.self, from: data),
            !queue.items.isEmpty
        else { return nil }
        return queue
    }

    static func write(_ queue: PersistedQueue?, to url: URL) {
        guard let queue, !queue.items.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? WireCoding.encoder.encode(queue) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Writes uploaded attachments under the bridge's attachments directory, one folder per session.
enum AttachmentStore {
    static func save(
        _ attachments: [SendAttachment], sessionID: String, directory: String
    ) -> [StoredAttachment] {
        guard !attachments.isEmpty else { return [] }
        let dir = "\(directory)/\(sessionID)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var stored: [StoredAttachment] = []
        for attachment in attachments {
            guard let data = Data(base64Encoded: attachment.dataBase64) else { continue }
            let name =
                "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))-\(attachment.filename ?? "file.bin")"
            let path = "\(dir)/\(name)"
            guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { continue }
            stored.append(
                StoredAttachment(
                    file: FileRef(
                        path: path, mime: attachment.mime, filename: attachment.filename,
                        url: "/attachments/\(sessionID)/\(name)"),
                    size: data.count))
        }
        return stored
    }
}
