import Foundation

enum HubEvent: Sendable {
    case session(id: String, event: BridgeEvent)
    case listUpsert(SessionSummary)
    case listRemove(id: String)
    case agents(sessionID: String, agents: [SubagentSummary])
    case heartbeat(seq: UInt64)
}

struct HubFrame: Sendable {
    let seq: UInt64
    let event: HubEvent
}

actor Hub {
    let epoch: String
    private(set) var seq: UInt64 = 0
    private var ring: [HubFrame] = []
    private static let ringLimit = 8192
    private var subscribers: [UUID: AsyncStream<HubFrame>.Continuation] = [:]

    init() {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        epoch = String((0..<12).map { _ in alphabet.randomElement()! })
    }

    var oldestReplayableSeq: UInt64 { ring.first?.seq ?? seq &+ 1 }

    func publish(_ event: HubEvent) {
        seq &+= 1
        let frame = HubFrame(seq: seq, event: event)
        ring.append(frame)
        if ring.count > Self.ringLimit { ring.removeFirst(ring.count - Self.ringLimit) }
        for continuation in subscribers.values { continuation.yield(frame) }
    }

    func oldestReplayableSeqValue() -> UInt64 { oldestReplayableSeq }

    func publishHeartbeat() {
        let frame = HubFrame(seq: 0, event: .heartbeat(seq: seq))
        for continuation in subscribers.values { continuation.yield(frame) }
    }

    func runHeartbeats() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            publishHeartbeat()
        }
    }

    struct Attachment {
        let id: UUID
        let stream: AsyncStream<HubFrame>
        let replay: [HubFrame]
        let tooOld: Bool
        let headSeq: UInt64
    }

    func attach(sinceEpoch: String?, sinceSeq: UInt64?) -> Attachment {
        let id = UUID()
        var replay: [HubFrame] = []
        var tooOld = false
        if let sinceEpoch, let sinceSeq {
            if sinceEpoch == epoch, sinceSeq &+ 1 >= oldestReplayableSeq {
                replay = ring.filter { $0.seq > sinceSeq }
            } else {
                tooOld = true
            }
        }
        let stream = AsyncStream<HubFrame>(bufferingPolicy: .bufferingNewest(4096)) {
            continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.detach(id) }
            }
        }
        return Attachment(id: id, stream: stream, replay: replay, tooOld: tooOld, headSeq: seq)
    }

    func detach(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    func closeAll() {
        for (_, continuation) in subscribers { continuation.finish() }
        subscribers.removeAll()
    }
}

struct StreamHello: Encodable {
    let proto: Int
    let epoch: String
    let seq: UInt64
    let oldestSeq: UInt64
    let heartbeat: Int
    let reset: Bool
}

struct Heartbeat: Encodable {
    let seq: UInt64
    let t: Date
}

struct SessionFramePayload: Encodable {
    let session: String
    let event: BridgeEvent
}

struct AgentsFramePayload: Encodable {
    let session: String
    let agents: [SubagentSummary]
}
