import Foundation

/// Names a conversation after its first exchange with a one-shot `omp -p` call — no session file,
/// no tools, no skills, no thinking — so a title costs one short completion rather than a second
/// agent.
///
/// omp writes an empty title row at the top of every transcript and only ever fills it in from its
/// own terminal UI; under the bridge that row stays empty for the life of the chat. Without this
/// every session kept the slice of first prompt it was born with, which for a slash command read
/// like a command line rather than a conversation.
enum Titler {
    /// The title for an exchange, or nil when the call failed, timed out or came back with
    /// something that is not a title. A nil is never fatal: the row keeps the name it has.
    ///
    /// The session's own engine is asked first and whatever omp reaches for by default second, so
    /// a chat is not left with a command line for a name because the model it happened to run on
    /// wants a key this service does not carry, or is too large to load for six words.
    static func title(
        binary: String, model: String?, cwd: String, user: String, assistant: String
    ) async -> String? {
        try? FileManager.default.createDirectory(
            atPath: cwd, withIntermediateDirectories: true)
        let prompt = """
            Write a title for this coding-agent conversation: 3 to 6 words, plain text, \
            no quotes, no trailing period. Reply with the title only.

            User: \(condense(user, cap: 600))
            Assistant: \(condense(assistant, cap: 400))
            """
        if let raw = await run(binary: binary, model: model, cwd: cwd, prompt: prompt),
            let named = clean(raw)
        {
            return named
        }
        guard model != nil else { return nil }
        return await run(binary: binary, model: nil, cwd: cwd, prompt: prompt).flatMap(clean)
    }

    /// What a look at the title decided, on claude-bridge's grammar: `moved` names which of the
    /// messages shown (from one, oldest first) the new topic began at; `failed` is no usable answer
    /// and is never read as `kept`, so the next turn asks again.
    enum Verdict: Equatable, Sendable {
        case kept
        case renamed(String)
        case moved(title: String, start: Int)
        case failed
    }

    /// Whether a conversation that has been going a while still wears the right name, and if the
    /// topic moved, where — asked of the session's engine first and omp's default second.
    static func revised(
        binary: String, model: String?, cwd: String, current: String, prompts: [String],
        assistant: String
    ) async -> Verdict {
        guard !prompts.isEmpty else { return .failed }
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let numbered = prompts.enumerated().map { index, text in
            "Message \(index + 1): \(condense(text, cap: 400))"
        }.joined(separator: "\n")
        let prompt = """
            A coding-agent conversation is titled "\(current)". Below are the person's newest \
            messages, numbered, and the agent's latest answer. Reply with exactly one line:
            KEEP — the title still fits what the conversation is focused on now.
            RENAME: <title> — the same focus, but the title could say it better.
            MOVED <n>: <title> — the focus has shifted to a new task, problem or phase of the work, \
            even within the same project, and the shift began at message <n>. A single side \
            question is not a shift.
            A title is 3 to 6 words, plain text, no quotes, no trailing period.

            \(numbered)
            Answer: \(condense(assistant, cap: 400))
            """
        for engine in model == nil ? [nil] : [model, nil] {
            guard let raw = await run(binary: binary, model: engine, cwd: cwd, prompt: prompt, system: format)
            else { continue }
            let verdict = verdict(from: raw, current: current, count: prompts.count)
            if verdict != .failed { return verdict }
        }
        return .failed
    }

    /// Reads a look's reply: the last line that is one of the three shapes, after any thinking a
    /// local engine printed first. A bare title is a rename, never a move; a new title that only
    /// restates the current one is a KEEP.
    static func verdict(from raw: String, current: String, count: Int) -> Verdict {
        let lines = answerLines(raw)
        for line in lines.reversed() {
            if line.range(of: #"^keep\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return .kept
            }
            if let match = line.firstMatch(of: #/^(?i:moved)\s*(\d{1,3})\s*:\s*(.+)$/#) {
                guard let title = clean(String(match.2)), !same(title, current) else { return .kept }
                let number = Int(match.1) ?? count
                return .moved(title: title, start: (1...max(1, count)).contains(number) ? number : count)
            }
            if let match = line.firstMatch(of: #/^(?i:rename)\s*:\s*(.+)$/#) {
                guard let title = clean(String(match.1)), !same(title, current) else { return .kept }
                return .renamed(title)
            }
        }
        guard let last = lines.last, !last.contains(":"), let title = clean(last) else { return .failed }
        return same(title, current) ? .kept : .renamed(title)
    }

    /// One sentence saying what a finished stretch of the conversation came to.
    static func gist(
        binary: String, model: String?, cwd: String, title: String, prompts: [String], answer: String
    ) async -> String? {
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let said = prompts.map { "Person: \(condense($0, cap: 200))" }.joined(separator: "\n")
        let prompt = """
            Here is one stretch of a coding-agent conversation, titled "\(title)": the person's \
            messages in it, oldest first, and the agent's last answer in it. In one plain sentence \
            of at most 16 words, say what this stretch did or decided, in the past tense. Say \
            something was finished, shipped or released only if the last answer says it was; \
            otherwise say what was worked on or proposed. No preamble, no quotes. Reply with the \
            sentence only.

            \(said)
            Answer: \(condense(answer, cap: 600))
            """
        for engine in model == nil ? [nil] : [model, nil] {
            if let raw = await run(binary: binary, model: engine, cwd: cwd, prompt: prompt, system: format),
                let line = gistLine(from: raw)
            {
                return line
            }
        }
        return nil
    }

    static func gistLine(from raw: String) -> String? {
        guard let line = answerLines(raw).last else { return nil }
        let sentence = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”`*_ "))
        guard !sentence.isEmpty, sentence.count <= 220 else { return nil }
        return sentence
    }

    /// One stretch a conversation's history was split into: the message it began at (from one, in
    /// the list shown), its title and what it came to.
    struct Segment: Equatable, Sendable {
        var start: Int
        var title: String
        var gist: String?
    }

    /// Splits a conversation that already happened into its chapters, once, for one older than
    /// chapters.
    static func segments(
        binary: String, model: String?, cwd: String, current: String, prompts: [String]
    ) async -> [Segment]? {
        guard !prompts.isEmpty else { return nil }
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let numbered = prompts.enumerated().map { index, text in
            "\(index + 1): \(condense(text, cap: 160))"
        }.joined(separator: "\n")
        let prompt = """
            Below are the person's messages in a coding-agent conversation now titled \
            "\(current)", numbered, oldest first. Split the conversation into its chapters: \
            stretches in which the focus stayed on one task, problem or phase of the work. A single \
            side question is not a chapter, and every chapter spans at least two messages. Most \
            conversations have one to six chapters; give at most \(mostChapters(among: prompts.count)). \
            Reply with one line per chapter, oldest first, and nothing else:
            <number of the message it began at> | <title, 3 to 6 words, plain text> | <one \
            past-tense sentence of at most 16 words saying what that stretch did or decided>
            The number is the message's own number from the list below, not the chapter's: a \
            chapter that began at message 12 starts its line with 12. Leave the last chapter's \
            sentence empty: it is still going. The first chapter begins at message 1.

            \(numbered)
            """
        for engine in model == nil ? [nil] : [model, nil] {
            if let raw = await run(
                binary: binary, model: engine, cwd: cwd, prompt: prompt, system: format,
                timeout: splitTimeout),
                let found = segments(from: raw, count: prompts.count)
            {
                return found
            }
        }
        return nil
    }

    static func segments(from raw: String, count: Int) -> [Segment]? {
        var result: [Segment] = []
        for line in answerLines(raw) {
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`#>-"))
            let fields = cleaned.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, let start = Int(fields[0]), (1...max(1, count)).contains(start),
                let title = clean(fields[1])
            else { continue }
            let gist = fields.count > 2 ? gistLine(from: fields[2]) : nil
            if result.isEmpty {
                result.append(Segment(start: 1, title: title, gist: gist))
            } else if start > result[result.count - 1].start {
                result.append(Segment(start: start, title: title, gist: gist))
            }
        }
        guard !result.isEmpty, !isDegenerate(result, count: count) else { return nil }
        result = coarsened(result, count: count)
        result[result.count - 1].gist = nil
        return result
    }

    /// The most chapters a split of `count` messages keeps: one per three messages, at least two
    /// and at most twelve. Chapters are coarse phases.
    static func mostChapters(among count: Int) -> Int {
        min(12, max(2, count / 3))
    }

    /// A split that tells nothing a list of the messages would not: a weaker engine sometimes opens
    /// a chapter at nearly every message, or numbers its chapters 1, 2, 3 where it was asked for
    /// the message each began at. Such an answer is no answer, and the next engine is asked.
    static func isDegenerate(_ segments: [Segment], count: Int) -> Bool {
        guard segments.count >= 3 else { return false }
        if segments.count > count / 2 { return true }
        return segments.map(\.start) == Array(1...segments.count)
    }

    /// Folds the shortest chapter after the first into the one before it, the earliest of equals
    /// first, until no more than ``mostChapters(among:)`` are left. An engine asked for coarse
    /// phases often answers finer ones that are each sensible; the one folded in was the smaller
    /// side trip, and the chapter it joins keeps its name and what it came to.
    static func coarsened(_ segments: [Segment], count: Int) -> [Segment] {
        var kept = segments
        while kept.count > mostChapters(among: count) {
            let lengths = kept.indices.map { index in
                (index + 1 < kept.count ? kept[index + 1].start : count + 1) - kept[index].start
            }
            let fold = kept.indices.dropFirst().min { lengths[$0] < lengths[$1] } ?? kept.count - 1
            kept.remove(at: fold)
        }
        return kept
    }

    /// The reply's lines with any thinking a local engine printed first taken out, and the
    /// markdown around a line stripped.
    private static func answerLines(_ raw: String) -> [String] {
        var text = raw.replacingOccurrences(
            of: "(?s)<think>.*?</think>", with: " ", options: .regularExpression)
        if let end = text.range(of: "</think>", options: .backwards) {
            text = String(text[end.upperBound...])
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_`#>")) }
            .filter { !$0.isEmpty }
    }

    private static func same(_ title: String, _ current: String) -> Bool {
        title.caseInsensitiveCompare(current) == .orderedSame
    }

    private static let format = "You answer in exactly the format asked, with nothing else."

    private static func condense(_ text: String, cap: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(flattened.prefix(cap))
    }

    /// The title inside whatever the engine printed. A local model is the likely titler here — it
    /// is the one already warm on the machine — and a local model will sometimes think out loud or
    /// announce itself first, so the last real line wins and anything that is not title-shaped is
    /// refused rather than written into the list.
    static func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(
            of: "(?s)<think>.*?</think>", with: " ", options: .regularExpression)
        if let end = text.range(of: "</think>", options: .backwards) {
            text = String(text[end.upperBound...])
        }
        guard
            var line = text
                .split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty })
        else { return nil }
        line = line.replacingOccurrences(
            of: "^(?i)(title|session title)\\s*[:\\-]\\s*", with: "",
            options: .regularExpression)
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”`*_ .,:;"))
        guard !line.isEmpty, line.count <= 70, line.split(separator: " ").count <= 12 else {
            return nil
        }
        return line
    }

    private static func run(
        binary: String, model: String?, cwd: String, prompt: String,
        system: String = "You write short titles.", timeout: TimeInterval = timeout
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                var arguments = [
                    "-p", "--no-session", "--no-tools", "--no-lsp", "--no-skills", "--no-rules",
                    "--no-extensions", "--no-title", "--thinking", "off",
                    "--system-prompt", system,
                ]
                if let model, !model.isEmpty { arguments.append(contentsOf: ["--model", model]) }
                arguments.append(prompt)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = OmpProcess.pathReachingRuntime(
                    of: binary, base: environment["PATH"])
                process.environment = environment
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// Long enough for a cold local engine to load and answer, short enough that a wedged one is
    /// let go of rather than held onto.
    private static let timeout: TimeInterval = 60
    /// A split reads up to ``ChapterBook/backfillShown`` messages and writes a line per chapter,
    /// which a local engine takes far longer over than a title.
    private static let splitTimeout: TimeInterval = 240
}
