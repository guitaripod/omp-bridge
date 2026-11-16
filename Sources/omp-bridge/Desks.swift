import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// What a desktop Tailscode says about the person in front of it, the shape CodingAgentKit's
/// `DeskReport` writes. Every field but the desk's own id may be missing from a newer or older
/// client and reads as the quiet default.
struct DeskReportBody: Codable, Sendable, Equatable {
    var desk: String
    var name: String
    var idle: Int?
    var locked: Bool
    var leaving: Bool
    var looked: [String]

    init(
        desk: String, name: String, idle: Int?, locked: Bool = false, leaving: Bool = false,
        looked: [String] = []
    ) {
        self.desk = desk
        self.name = name
        self.idle = idle
        self.locked = locked
        self.leaving = leaving
        self.looked = looked
    }

    private enum CodingKeys: String, CodingKey {
        case desk, name, idle, locked, leaving, looked
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        desk = try values.decode(String.self, forKey: .desk)
        name = (try? values.decodeIfPresent(String.self, forKey: .name)) ?? ""
        idle = try? values.decodeIfPresent(Int.self, forKey: .idle)
        locked = (try? values.decodeIfPresent(Bool.self, forKey: .locked)) ?? false
        leaving = (try? values.decodeIfPresent(Bool.self, forKey: .leaving)) ?? false
        looked = (try? values.decodeIfPresent([String].self, forKey: .looked)) ?? []
    }
}

/// One desk as a device reads it: idle as of the answer, and how long ago it was heard.
struct DeskBody: Codable, Sendable, Equatable {
    var desk: String
    var name: String
    var idle: Int?
    var locked: Bool
    var heard: Int
}

/// The answer to `GET /presence` and `GET /presence/wait`, the shape CodingAgentKit's
/// `DeskPresence` reads.
struct DeskPresenceBody: Codable, Sendable, Equatable {
    var desks: [DeskBody]
    var looked: [String: Date]
    var away: Bool?
}

/// The desks reporting to this bridge, and the conversations they had on screen.
///
/// Nothing here is persisted: a desk reports every 30 s, so one this process has not heard from
/// since it started is a desk nobody is at. A desk silent for `staleAfter` is gone (the app quit,
/// the machine slept, the network dropped), and one that says it is leaving is gone at once.
/// Locked so every route can ask without crossing an actor.
final class DeskRegistry: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        var report: DeskReportBody
        var heardAt: Date
    }

    static let staleAfter: TimeInterval = 90
    /// The patience a wait that named none gets: Tailscode's own default.
    static let defaultAwayAfter: TimeInterval = 120
    static let lookedKept: TimeInterval = 86_400
    static let deskLimit = 32
    static let lookedPerReport = 64
    static let textLimit = 200

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var looks: [String: Date] = [:]

    /// Takes a report, trimmed to what a well-behaved desk ever sends. Returns false for one
    /// that names no desk.
    @discardableResult
    func record(_ report: DeskReportBody, now: Date = Date()) -> Bool {
        let id = String(report.desk.prefix(Self.textLimit))
        guard !id.isEmpty else { return false }
        var report = report
        report.desk = id
        report.name = String(report.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.textLimit))
        report.idle = report.idle.map { max(0, $0) }
        let looked = report.looked.prefix(Self.lookedPerReport)
            .filter { !$0.isEmpty && $0.count <= Self.textLimit }
        report.looked = []
        lock.withLock {
            for sessionID in looked { looks[sessionID] = now }
            if report.leaving {
                entries[id] = nil
            } else {
                entries[id] = Entry(report: report, heardAt: now)
            }
            prune(now: now)
        }
        return true
    }

    /// Every desk still worth reading, idle as of `now`.
    func presence(now: Date = Date(), away: Bool? = nil) -> DeskPresenceBody {
        lock.withLock {
            prune(now: now)
            let desks = entries.values
                .sorted { $0.report.desk < $1.report.desk }
                .map { entry in
                    let heard = max(0, now.timeIntervalSince(entry.heardAt))
                    return DeskBody(
                        desk: entry.report.desk, name: entry.report.name,
                        idle: entry.report.idle.map { $0 + Int(heard.rounded(.down)) },
                        locked: entry.report.locked, heard: Int(heard.rounded(.down)))
                }
            return DeskPresenceBody(desks: desks, looked: looks, away: away)
        }
    }

    /// The desk the person is at by this patience: heard lately, unlocked, input within
    /// `awayAfter`. The freshest input when several qualify.
    func occupied(awayAfter: TimeInterval, now: Date = Date()) -> DeskBody? {
        presence(now: now).desks
            .filter { desk in
                guard !desk.locked, TimeInterval(desk.heard) < Self.staleAfter, let idle = desk.idle
                else { return false }
                return TimeInterval(idle) < awayAfter
            }
            .min { ($0.idle ?? .max) < ($1.idle ?? .max) }
    }

    /// Whether a desk had this conversation on screen at or after `moment`.
    func looked(_ sessionID: String, since moment: Date) -> Bool {
        lock.withLock { looks[sessionID].map { $0 >= moment } ?? false }
    }

    private func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.heardAt) < Self.staleAfter }
        if entries.count > Self.deskLimit {
            let kept = entries.values.sorted { $0.heardAt > $1.heardAt }.prefix(Self.deskLimit)
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.report.desk, $0) })
        }
        looks = looks.filter { now.timeIntervalSince($0.value) < Self.lookedKept }
    }
}

/// `POST /presence` takes a desk's report; `GET /presence` answers what is known; `GET
/// /presence/wait?awayAfter=N` holds until nobody has been at a desk for N seconds, the way
/// `/sessions/:id/wait` holds for a turn: a `\n` at once and every ten seconds, then one answer,
/// `away: true`, or `away: false` once `waitMax` has passed so the caller simply asks again. This
/// bridge pushes nothing, so it holds no notices: it answers for the desks so a phone that holds
/// only this bridge can still tell whether its person is at a computer.
func registerDeskRoutes(
    _ router: Router<BasicRequestContext>, desks: DeskRegistry, waitMax: TimeInterval
) {
    router.post("presence") { request, _ in
        guard let body = try? await decodeBody(DeskReportBody.self, request, limit: 64 * 1024),
            desks.record(body)
        else {
            return jsonResponse(["error": "bad request"], status: .badRequest)
        }
        return jsonResponse(["ok": true])
    }

    router.get("presence") { _, _ in
        jsonResponse(desks.presence())
    }

    router.get("presence/wait") { request, _ in
        let raw = request.uri.queryParameters.get("awayAfter").flatMap { Double($0) }
        let awayAfter = max(1, raw ?? DeskRegistry.defaultAwayAfter)
        let deadline = Date().addingTimeInterval(waitMax)
        let body = ResponseBody { writer in
            func send(_ value: DeskPresenceBody) async throws {
                let data = (try? WireCoding.encoder.encode(value)) ?? Data("{}".utf8)
                var buffer = ByteBuffer()
                buffer.writeBytes(data)
                try await writer.write(buffer)
                try await writer.finish(nil)
            }
            func heartbeat() async throws {
                var buffer = ByteBuffer()
                buffer.writeString("\n")
                try await writer.write(buffer)
            }
            try await heartbeat()
            var lastHeartbeat = Date()
            while true {
                let now = Date()
                if desks.occupied(awayAfter: awayAfter, now: now) == nil {
                    return try await send(desks.presence(now: now, away: true))
                }
                if now >= deadline {
                    return try await send(desks.presence(now: now, away: false))
                }
                if now.timeIntervalSince(lastHeartbeat) >= 10 {
                    try await heartbeat()
                    lastHeartbeat = now
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: body)
    }
}
