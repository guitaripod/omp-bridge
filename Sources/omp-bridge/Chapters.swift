import Foundation

/// A stretch of the conversation under one title, on claude-bridge's wire. A chapter begins where
/// the bridge judged that the topic had moved on; a new name for the same stretch renames the
/// chapter rather than starting another.
struct Chapter: Codable, Sendable, Equatable {
    var title: String
    /// The person's message the chapter begins at, counted from one. The turn is what is kept: a
    /// message's id is not, because oh-my-pi's transcript names a message differently from the
    /// live turn that wrote it, so the id is worked out again from the turn whenever it is served.
    var turn: Int
    var messageID: String?
    var startedAt: Date
    /// What the chapter came to, in one sentence, once the next one has begun.
    var gist: String?
    var namedBy: Namer

    enum Namer: String, Codable, Sendable {
        case prompt, model, person, agent, schedule, fork, kept
    }
}

/// The chapter rules as functions of a conversation's messages and chapters, so every way a name
/// changes is decided in one place and can be checked without an engine.
enum ChapterBook {
    static let lookBack = 4
    static let backfillFloor = 6
    static let backfillShown = 150

    static func prompts(in messages: [Message]) -> [(turn: Int, message: Message)] {
        var turn = 0
        var result: [(turn: Int, message: Message)] = []
        for message in messages where message.role == .user {
            turn += 1
            result.append((turn, message))
        }
        return result
    }

    static func text(of message: Message) -> String {
        message.parts.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }

    static func openingNamer(customTitle: Bool, scheduled: Bool) -> Chapter.Namer {
        if scheduled { return .schedule }
        if customTitle { return .person }
        return .prompt
    }

    /// The person's message was just added: the first one opens chapter one, and a later one that
    /// changed the prompt-derived name renames it.
    static func recorded(
        _ chapters: inout [Chapter], messages: [Message], title: String, priorTitle: String,
        namer: Chapter.Namer
    ) -> Bool {
        let all = prompts(in: messages)
        if chapters.isEmpty {
            guard all.count == 1, let first = all.first else { return false }
            chapters = [
                Chapter(
                    title: title, turn: 1, messageID: first.message.id,
                    startedAt: first.message.createdAt, gist: nil, namedBy: namer)
            ]
            return true
        }
        guard title != priorTitle else { return false }
        return renamed(&chapters, messages: messages, to: title, by: .prompt, priorTitle: priorTitle)
    }

    /// Chapter one, written from the name the conversation wore before, for one with history and
    /// no chapters. Past its first message it may have worn other names that are not known.
    static func seeded(
        _ chapters: inout [Chapter], messages: [Message], priorTitle: String,
        namer: Chapter.Namer = .prompt
    ) {
        guard chapters.isEmpty else { return }
        let all = prompts(in: messages)
        guard let first = all.first else { return }
        chapters = [
            Chapter(
                title: priorTitle, turn: 1, messageID: first.message.id,
                startedAt: first.message.createdAt, gist: nil,
                namedBy: all.count > 1 ? .kept : namer)
        ]
    }

    @discardableResult
    static func renamed(
        _ chapters: inout [Chapter], messages: [Message], to title: String, by namer: Chapter.Namer,
        priorTitle: String
    ) -> Bool {
        seeded(&chapters, messages: messages, priorTitle: priorTitle)
        guard let last = chapters.indices.last else { return false }
        guard chapters[last].title != title || chapters[last].namedBy != namer else { return false }
        chapters[last].title = title
        chapters[last].namedBy = namer
        return true
    }

    /// The topic moved: a chapter opens at the person's `turn`-th message, and the index of the
    /// chapter it closes comes back. A boundary at or before the current chapter's start moves to
    /// the message after it; when there is none, nothing opens.
    static func opened(
        _ chapters: inout [Chapter], messages: [Message], title: String, atTurn turn: Int,
        priorTitle: String
    ) -> Int? {
        seeded(&chapters, messages: messages, priorTitle: priorTitle)
        let all = prompts(in: messages)
        guard let last = chapters.last, var start = all.first(where: { $0.turn == turn }) else {
            return nil
        }
        if start.turn <= last.turn {
            guard let next = all.first(where: { $0.turn > last.turn }) else { return nil }
            start = next
        }
        chapters.append(
            Chapter(
                title: title, turn: start.turn, messageID: start.message.id,
                startedAt: start.message.createdAt, gist: nil, namedBy: .model))
        return chapters.count - 2
    }

    static func forked(_ chapters: [Chapter], title: String) -> [Chapter] {
        guard let last = chapters.indices.last else { return chapters }
        var copy = chapters
        copy[last].title = title
        copy[last].namedBy = .fork
        copy[last].gist = nil
        return copy
    }

    /// The person's messages a look is shown: those since the last one, the newest `lookBack`.
    static func recent(_ messages: [Message], since titledAt: Int?, through turn: Int)
        -> [(turn: Int, message: Message)]
    {
        let floor = titledAt ?? 0
        let span = prompts(in: messages).filter {
            $0.turn > floor && $0.turn <= turn && !text(of: $0.message).isEmpty
        }
        return Array(span.suffix(lookBack))
    }

    /// The exchange a first model title is written from: the opening message of the chapter the
    /// conversation is in and the first answer after it — for a fork, where its own stretch began.
    static func opening(_ chapters: [Chapter], messages: [Message]) -> (user: String, answer: String)? {
        let all = prompts(in: messages)
        let start = chapters.last.flatMap { last in all.first { $0.turn == last.turn } } ?? all.first
        guard let start, let index = messages.firstIndex(where: { $0.id == start.message.id }) else {
            return nil
        }
        let user = text(of: messages[index])
        let answer = messages[(index + 1)...].first { $0.role == .assistant && !text(of: $0).isEmpty }
            .map(text(of:)) ?? ""
        guard !user.isEmpty, !answer.isEmpty else { return nil }
        return (user, answer)
    }

    /// What a closed chapter is summed up from: up to eight of the person's messages in it, taken
    /// evenly across it, and the last answer with words in it before the next chapter began.
    static func gistInput(_ chapters: [Chapter], messages: [Message], closed index: Int)
        -> (prompts: [String], answer: String)?
    {
        guard chapters.indices.contains(index), chapters.indices.contains(index + 1) else {
            return nil
        }
        let start = chapters[index].turn
        let end = chapters[index + 1].turn
        let all = prompts(in: messages)
        let inside = all.filter { $0.turn >= start && $0.turn < end && !text(of: $0.message).isEmpty }
        guard let lastPrompt = inside.last,
            let promptIndex = messages.firstIndex(where: { $0.id == lastPrompt.message.id })
        else { return nil }
        let nextIndex = all.first { $0.turn == end }
            .flatMap { next in messages.firstIndex { $0.id == next.message.id } } ?? messages.endIndex
        guard promptIndex < nextIndex else { return nil }
        let answer = messages[promptIndex..<nextIndex].reversed()
            .first { $0.role == .assistant && !text(of: $0).isEmpty }
            .map(text(of:)) ?? ""
        let picked = inside.count > 8
            ? (0..<8).map { inside[$0 * (inside.count - 1) / 7] } : inside
        let texts = picked.map { text(of: $0.message) }
        guard !texts.isEmpty, !answer.isEmpty else { return nil }
        return (texts, answer)
    }

    /// Puts a gist on the chapter it was written for, found again by when it began — its turn may
    /// have been re-counted meanwhile — so a conversation cleared or re-chaptered while the gist
    /// was being written is left alone.
    static func summed(_ chapters: inout [Chapter], chapter: Chapter, gist: String) -> Bool {
        guard let index = chapters.firstIndex(where: { $0.startedAt == chapter.startedAt }),
            chapters[index].gist == nil
        else { return false }
        chapters[index].gist = gist
        return true
    }

    /// The person's messages a history is split from, thinned evenly to `backfillShown`.
    static func backfillPrompts(_ messages: [Message]) -> [(turn: Int, message: Message)] {
        let spoken = prompts(in: messages).filter { !text(of: $0.message).isEmpty }
        guard spoken.count > backfillShown else { return spoken }
        return (0..<backfillShown).map { spoken[$0 * (spoken.count - 1) / (backfillShown - 1)] }
    }

    /// Chapters for a conversation that had none, from the stretches its history was split into;
    /// the last keeps the conversation's own name. Nil when it gained chapters meanwhile.
    static func backfilled(
        _ chapters: [Chapter], messages: [Message], title: String, customTitle: Bool,
        segments: [Titler.Segment], shown: [(turn: Int, message: Message)]
    ) -> [Chapter]? {
        guard chapters.isEmpty, !segments.isEmpty else { return nil }
        var result: [Chapter] = []
        for (index, segment) in segments.enumerated() {
            guard shown.indices.contains(segment.start - 1) else { continue }
            let opening = shown[segment.start - 1]
            guard prompts(in: messages).contains(where: { $0.turn == opening.turn }) else { return nil }
            let isLast = index == segments.count - 1
            result.append(
                Chapter(
                    title: isLast ? title : segment.title, turn: opening.turn,
                    messageID: opening.message.id, startedAt: opening.message.createdAt,
                    gist: isLast ? nil : segment.gist,
                    namedBy: isLast && customTitle ? .person : .model))
        }
        return result.isEmpty ? nil : result
    }

    /// How far a chapter's start may sit from the message it began at once the transcript has been
    /// read back: the live message is dated when the bridge echoed it, the transcript's when the
    /// engine took it, which a cold engine can put seconds apart.
    static let anchorSlack: TimeInterval = 30

    /// Counts each chapter's turn again against messages read back from the transcript, which can
    /// number the person's messages differently from the live turn — a slash command the engine
    /// answered itself is a message live and none on disk. A chapter is matched to the message
    /// nearest when it began, within ``anchorSlack``, and keeps its turn when none is near or the
    /// match would put it at or before the chapter ahead of it.
    static func reanchored(_ chapters: [Chapter], messages: [Message]) -> [Chapter] {
        let all = prompts(in: messages)
        var floor = 0
        return chapters.map { chapter in
            var copy = chapter
            let near = all.filter { abs($0.message.createdAt.timeIntervalSince(chapter.startedAt)) <= anchorSlack }
                .min { abs($0.message.createdAt.timeIntervalSince(chapter.startedAt))
                    < abs($1.message.createdAt.timeIntervalSince(chapter.startedAt)) }
            if let near, near.turn > floor {
                copy.turn = near.turn
                copy.messageID = near.message.id
            }
            floor = max(floor, copy.turn)
            return copy
        }
    }

    /// The chapters as served: each one's message id worked out again from its turn against the
    /// messages as they stand, so an id renamed by a restart still finds its message.
    static func resolved(_ chapters: [Chapter], messages: [Message]) -> [Chapter] {
        let all = prompts(in: messages)
        return chapters.map { chapter in
            var copy = chapter
            if let match = all.first(where: { $0.turn == chapter.turn }) {
                copy.messageID = match.message.id
            }
            return copy
        }
    }
}
