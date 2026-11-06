import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// `GET /sessions/:id/wait`'s body: the identical shape claude-bridge answers with, so the Kit
/// decodes both bridges the same way. Every field but `state` and `waited` is omitted, never
/// null, when this bridge does not know it — `background` never appears at all, since oh-my-pi
/// carries nothing like claude-bridge's background tasks to report.
struct TurnWait: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case ended
        case needsYou
        case running
    }

    enum Ending: String, Codable, Sendable {
        case finished
        case answerless
        case failed
        case interrupted
        case cancelled
        case question
        case approval
        case lost
    }

    var state: State
    var waited: Bool
    var ending: Ending? = nil
    var title: String? = nil
    var toolCount: Int? = nil
    var duration: Double? = nil
    var lastMessageID: String? = nil
    var endedAt: Date? = nil
    /// Held until the work settled (`until=settled`): nothing runs, queues or works for the
    /// conversation, and `duration` is the whole stretch of work.
    var settled: Bool? = nil
}

/// What a turn left behind, once ``OmpSession`` closes it — the only record `GET
/// /sessions/:id/wait` can still answer from after the fact, since the turn's own counters are
/// cleared for the next turn the moment it ends.
struct TurnOutcome: Sendable, Equatable {
    var ending: TurnWait.Ending
    var toolCount: Int?
    var duration: Double?
    var lastMessageID: String?
    var endedAt: Date
}

/// Holds a chunked `GET /sessions/:id/wait` open until a session stops moving or asks the person
/// something, writing a heartbeat newline every ``heartbeatInterval`` so the connection never
/// reads as dead to a client that decodes it byte by byte. A disconnected client ends the hold the
/// same way any other streaming route in this bridge does: the write that follows throws, and the
/// closure that owns the loop unwinds.
enum TurnWaitEngine {
    static let heartbeatInterval: TimeInterval = 10
    static let pollInterval: Duration = .milliseconds(200)
    /// How long the conversation must stay still before a wait held for settled work answers: long
    /// enough for a queued prompt or a subagent's report to have started the next turn. The same
    /// grace Tailscode and claude-bridge hold finished work to.
    static let grace: TimeInterval = 10

    static func run(
        session: OmpSession, maxWait: TimeInterval, untilSettled: Bool = false,
        writer: inout any ResponseBodyWriter
    ) async throws {
        try await writer.write(newline())
        let startedAt = Date()
        var lastHeartbeatAt = startedAt
        var waited = false
        while true {
            if let wait = await resolved(for: session, waited: waited, untilSettled: untilSettled) {
                try await emit(wait, writer: &writer)
                return
            }
            if Date().timeIntervalSince(startedAt) >= maxWait {
                try await emit(
                    TurnWait(state: .running, waited: true, title: await session.titleText()),
                    writer: &writer)
                return
            }
            waited = true
            if Date().timeIntervalSince(lastHeartbeatAt) >= heartbeatInterval {
                try await writer.write(newline())
                lastHeartbeatAt = Date()
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// The session's own answer to "is there still anything to wait for", read fresh on every
    /// poll. A pending question outranks everything else, since a turn holding on the person is
    /// not merely idle; otherwise this reads exactly the liveness `GET /sessions/:id/revision`
    /// reports (`running` or `externallyLive`) — a turn a terminal is running blocks the wait
    /// exactly as it blocks that route, and the periodic sweep that keeps `externallyLive` current
    /// is what makes polling this correct for one that has no events of its own to fire.
    ///
    /// Held for settled work, a turn that closed is not yet an answer: the queue, a subagent still
    /// at work or the grace keep the wait open, and the answer then speaks for the whole stretch.
    static func resolved(
        for session: OmpSession, waited: Bool, untilSettled: Bool = false, now: Date = Date()
    ) async -> TurnWait? {
        let title = await session.titleText()
        if let question = await session.pendingQuestion() {
            return TurnWait(
                state: .needsYou, waited: waited, ending: .question, title: title,
                lastMessageID: question.messageID)
        }
        let running = await session.isRunningValue()
        let externallyLive = await session.externallyLiveValue()
        guard !running, !externallyLive else { return nil }
        guard untilSettled else {
            guard let outcome = await session.lastOutcomeSnapshot() else {
                return TurnWait(state: .ended, waited: waited, title: title)
            }
            return TurnWait(
                state: .ended, waited: waited, ending: outcome.ending, title: title,
                toolCount: outcome.toolCount, duration: outcome.duration,
                lastMessageID: outcome.lastMessageID, endedAt: outcome.endedAt)
        }
        guard await !session.carriesWork() else { return nil }
        guard let outcome = await session.lastOutcomeSnapshot() else {
            return TurnWait(state: .ended, waited: waited, title: title, settled: true)
        }
        guard now.timeIntervalSince(outcome.endedAt) >= grace else { return nil }
        let began = await session.workBegan
        return TurnWait(
            state: .ended, waited: waited, ending: outcome.ending, title: title,
            toolCount: outcome.toolCount,
            duration: began.map { max(0, outcome.endedAt.timeIntervalSince($0)) } ?? outcome.duration,
            lastMessageID: outcome.lastMessageID, endedAt: outcome.endedAt, settled: true)
    }

    private static func newline() -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeString("\n")
        return buffer
    }

    private static func emit(_ wait: TurnWait, writer: inout any ResponseBodyWriter) async throws {
        let data = (try? WireCoding.encoder.encode(wait)) ?? Data("{}".utf8)
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        try await writer.write(buffer)
        try await writer.finish(nil)
    }
}
